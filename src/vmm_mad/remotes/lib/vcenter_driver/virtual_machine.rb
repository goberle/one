module VCenterDriver

class VirtualMachineFolder
    attr_accessor :item, :items

    def initialize(item)
        @item = item
        @items = {}
    end

    ########################################################################
    # Builds a hash with Datastore-Ref / Datastore to be used as a cache
    # @return [Hash] in the form
    #   { ds_ref [Symbol] => Datastore object }
    ########################################################################
    def fetch!
        VIClient.get_entities(@item, "VirtualMachine").each do |item|
            item_name = item._ref
            @items[item_name.to_sym] = VirtualMachine.new(item)
        end
    end

    def fetch_templates!
        VIClient.get_entities(@item, "VirtualMachine").each do |item|
            if item.config.template
                item_name = item._ref
                @items[item_name.to_sym] = Template.new(item)
            end
        end
    end

    ########################################################################
    # Returns a Datastore. Uses the cache if available.
    # @param ref [Symbol] the vcenter ref
    # @return Datastore
    ########################################################################
    def get(ref)
        if !@items[ref.to_sym]
            rbvmomi_dc = RbVmomi::VIM::Datastore.new(@item._connection, ref)
            @items[ref.to_sym] = Datastore.new(rbvmomi_dc)
        end

        @items[ref.to_sym]
    end
end # class VirtualMachineFolder

class Template

    attr_accessor :item

    include Memoize

    def initialize(item=nil, vi_client=nil)
        @item = item
        @vi_client = vi_client
        @locking = true
    end

    # Locking function. Similar to flock
    def lock
        if @locking
           @locking_file = File.open("/tmp/vcenter-importer-lock","w")
           @locking_file.flock(File::LOCK_EX)
        end
    end

    # Unlock driver execution mutex
    def unlock
        if @locking
            @locking_file.close
        end
    end

    def get_dc
        item = @item

        while !item.instance_of? RbVmomi::VIM::Datacenter
            item = item.parent
            if item.nil?
                raise "Could not find the parent Datacenter"
            end
        end

        Datacenter.new(item)
    end

    def delete_template
        @item.Destroy_Task.wait_for_completion
    end

    def get_vcenter_instance_uuid
        @vi_client.vim.serviceContent.about.instanceUuid rescue nil
    end

    def create_template_copy(template_name)
        error = nil
        template_ref = nil

        template_name = "one-#{self['name']}" if template_name.empty?

        relocate_spec_params = {}
        relocate_spec_params[:pool] = get_rp
        relocate_spec = RbVmomi::VIM.VirtualMachineRelocateSpec(relocate_spec_params)

        clone_spec = RbVmomi::VIM.VirtualMachineCloneSpec({
            :location => relocate_spec,
            :powerOn  => false,
            :template => false
        })

        template = nil
        begin
            template = @item.CloneVM_Task(:folder => @item.parent,
                                          :name   => template_name,
                                          :spec   => clone_spec).wait_for_completion
            template_ref = template._ref
        rescue Exception => e
            if !e.message.start_with?('DuplicateName')
                error = "Could not create the template clone. Reason: #{e.message}"
                return error, nil
            end

            dc = get_dc
            vm_folder = dc.vm_folder
            vm_folder.fetch!
            vm = vm_folder.items
                    .select{|k,v| v.item.name == template_name}
                    .values.first.item rescue nil

            if vm
                begin
                    vm.Destroy_Task.wait_for_completion
                    template = @item.CloneVM_Task(:folder => @item.parent,
                                                  :name   => template_name,
                                                  :spec   => clone_spec).wait_for_completion
                    template_ref = template._ref
                rescue
                    error = "Could not delete the existing template, please remove it manually from vCenter. Reason: #{e.message}"
                end
            else
                error = "Could not create the template clone. Reason: #{e.message}"
            end
        end

        return error, template_ref
    end

    # Linked Clone over existing template
    def create_delta_disks

        begin
            disks = @item['config.hardware.device'].grep(RbVmomi::VIM::VirtualDisk)
            disk_without_snapshots = disks.select { |x| x.backing.parent.nil? }
        rescue
            error = "Cannot extract existing disks on template."
            use_linked_clones = false
            return error, use_linked_clones
        end

        if !disk_without_snapshots.empty?

            begin
                if self['config.template']
                    @item.MarkAsVirtualMachine(:pool => get_rp, :host => self['runtime.host'])
                end
            rescue Exception => e
                @item.MarkAsTemplate()
                error = "Cannot mark the template as a VirtualMachine. Not using linked clones. Reason: #{e.message}/#{e.backtrace}"
                use_linked_clones = false
                return error, use_linked_clones
            end

            begin
                spec = {}
                spec[:deviceChange] = []

                disk_without_snapshots.each do |disk|
                    remove_disk_spec = { :operation => :remove, :device => disk }
                    spec[:deviceChange] << remove_disk_spec

                    add_disk_spec = { :operation => :add,
                                    :fileOperation => :create,
                                    :device => disk.dup.tap { |x|
                                            x.backing = x.backing.dup
                                            x.backing.fileName = "[#{disk.backing.datastore.name}]"
                                            x.backing.parent = disk.backing
                                    }
                    }
                    spec[:deviceChange] << add_disk_spec
                end

                @item.ReconfigVM_Task(:spec => spec).wait_for_completion if !spec[:deviceChange].empty?
            rescue Exception => e
                error = "Cannot create the delta disks on top of the template. Reason: #{e.message}."
                use_linked_clones = false
                return error, use_linked_clones
            end

            begin
                @item.MarkAsTemplate()
            rescue
                error = "Cannot mark the VirtualMachine as a template. Not using linked clones."
                use_linked_clones = false
                return error, use_linked_clones
            end

            error = nil
            use_linked_clones = true
            return error, use_linked_clones
        else
            # Template already has delta disks
            error = nil
            use_linked_clones = true
            return error, use_linked_clones
        end
    end

    def import_vcenter_disks(vc_uuid, dpool, ipool)
        disk_info = ""
        error = ""

        begin
            lock #Lock import operation, to avoid concurrent creation of images

            ccr_ref = self["runtime.host.parent._ref"]

            #Get disks and info required
            vc_disks = get_vcenter_disks

            # Track allocated images
            allocated_images = []

            vc_disks.each do |disk|
                datastore_found = VCenterDriver::Storage.get_one_image_ds_by_ref_and_ccr(disk[:datastore]._ref,
                                                                                        ccr_ref,
                                                                                        vc_uuid,
                                                                                        dpool)
                if datastore_found.nil?
                    error = "\n    ERROR: datastore #{disk[:datastore].name}: has to be imported first as an image datastore!\n"

                    #Rollback delete disk images
                    allocated_images.each do |i|
                        i.delete
                    end

                    break
                end

                image_import = VCenterDriver::Datastore.get_image_import_template(disk[:datastore].name,
                                                                                  disk[:path],
                                                                                  disk[:type],
                                                                                  disk[:prefix],
                                                                                  ipool)
                #Image is already in the datastore
                if image_import[:one]
                    # This is the disk info
                    disk_info << "DISK=[\n"
                    disk_info << "IMAGE_ID=\"#{image_import[:one]["ID"]}\",\n"
                    disk_info << "OPENNEBULA_MANAGED=\"NO\"\n"
                    disk_info << "]\n"
                elsif !image_import[:template].empty?
                    # Then the image is created as it's not in the datastore
                    one_i = VCenterDriver::VIHelper.new_one_item(OpenNebula::Image)

                    allocated_images << one_i

                    rc = one_i.allocate(image_import[:template], datastore_found['ID'].to_i)

                    if ::OpenNebula.is_error?(rc)
                        error = "    Error creating disk from template: #{rc.message}. Cannot import the template\n"

                        #Rollback delete disk images
                        allocated_images.each do |i|
                            i.delete
                        end

                        break
                    end

                    #Add info for One template
                    one_i.info
                    disk_info << "DISK=[\n"
                    disk_info << "IMAGE_ID=\"#{one_i["ID"]}\",\n"
                    disk_info << "IMAGE_UNAME=\"#{one_i["UNAME"]}\",\n"
                    disk_info << "OPENNEBULA_MANAGED=\"NO\"\n"
                    disk_info << "]\n"
                end
            end

        rescue Exception => e
            error = "There was an error trying to create an image for disk in vcenter template. Reason: #{e.message}"
        ensure
            unlock
        end

        return error, disk_info
    end

    def import_vcenter_nics(vc_uuid, npool, vcenter_instance_name,
                            template_ref, dc_name=nil)
        nic_info = ""
        error = ""

        begin
            lock #Lock import operation, to avoid concurrent creation of images

            if !dc_name
                dc = get_dc
                dc_name = dc.item.name
            end

            ccr_ref  = self["runtime.host.parent._ref"]
            ccr_name = self["runtime.host.parent.name"]

            #Get disks and info required
            vc_nics = get_vcenter_nics

            # Track allocated networks
            allocated_networks = []

            vc_nics.each do |nic|
                network_found = VCenterDriver::Network.get_unmanaged_vnet_by_ref(nic[:net_ref],
                                                                                 ccr_ref,
                                                                                 template_ref,
                                                                                 vc_uuid,
                                                                                 npool)
                #Network is already in the datastore
                if network_found
                    # This is the existing nic info
                    nic_info << "NIC=[\n"
                    nic_info << "NETWORK_ID=\"#{network_found["ID"]}\",\n"
                    nic_info << "OPENNEBULA_MANAGED=\"NO\"\n"
                    nic_info << "]\n"
                else
                    # Then the network has to be created as it's not in OpenNebula
                    one_vn = VCenterDriver::VIHelper.new_one_item(OpenNebula::VirtualNetwork)

                    allocated_networks << one_vn

                    unmanaged = true

                    one_vnet = VCenterDriver::Network.to_one_template(nic[:net_name],
                                                                      nic[:net_ref],
                                                                      nic[:pg_type],
                                                                      ccr_ref,
                                                                      ccr_name,
                                                                      vc_uuid,
                                                                      vcenter_instance_name,
                                                                      dc_name,
                                                                      unmanaged,
                                                                      template_ref)

                    # By default add an ethernet range to network size 255
                    ar_str = ""
                    ar_str << "AR=[\n"
                    ar_str << "TYPE=\"ETHER\",\n"
                    ar_str << "SIZE=\"255\"\n"
                    ar_str << "]\n"
                    one_vnet[:one] << ar_str

                    rc = one_vn.allocate(one_vnet[:one])

                    if ::OpenNebula.is_error?(rc)
                        error = "    Error creating virtual network from template: #{rc.message}. Cannot import the template\n"

                        #Rollback, delete virtual networks
                        allocated_networks.each do |n|
                            n.delete
                        end

                        break
                    end

                    #Add info for One template
                    one_vn.info
                    nic_info << "NIC=[\n"
                    nic_info << "NETWORK_ID=\"#{one_vn["ID"]}\",\n"
                    nic_info << "OPENNEBULA_MANAGED=\"NO\"\n"
                    nic_info << "]\n"
                end
            end

        rescue Exception => e
            error = "There was an error trying to create a virtual network for network in vcenter template. Reason: #{e.message}"
        ensure
            unlock
        end

        return error, nic_info
    end

    def get_vcenter_disk_key(unit_number, controller_key)

        key = nil

        @item["config.hardware.device"].each do |device|
            disk = {}

            if is_disk_or_iso?(device)
                disk[:device]    = device
                if device.controllerKey == controller_key &&
                   device.unitNumber == unit_number

                   key = device.key
                   break
                end
            end
        end

        return key
    end

    def get_vcenter_disks

        disks = []
        ide_controlled  = []
        sata_controlled = []
        scsi_controlled = []

        @item["config.hardware.device"].each do |device|
            disk = {}

            if device.is_a? RbVmomi::VIM::VirtualIDEController
                ide_controlled.concat(device.device)
            end

            if device.is_a? RbVmomi::VIM::VirtualSATAController
                sata_controlled.concat(device.device)
            end

            if device.is_a? RbVmomi::VIM::VirtualSCSIController
                scsi_controlled.concat(device.device)
            end

            if is_disk_or_iso?(device)
                disk[:device]    = device
                disk[:datastore] = device.backing.datastore
                disk[:path]      = device.backing.fileName
                disk[:path_wo_ds]= disk[:path].sub(/^\[(.*?)\] /, "")
                disk[:type]      = is_disk?(device) ? "OS" : "CDROM"
                disk[:key]       = device.key
                disk[:prefix]    = "hd" if ide_controlled.include?(device.key)
                disk[:prefix]    = "sd" if scsi_controlled.include?(device.key)
                disk[:prefix]    = "sd" if sata_controlled.include?(device.key)
                disks << disk
            end
        end

        return disks
    end

    def get_vcenter_nics
        nics = []
        @item["config.hardware.device"].each do |device|
            nic = {}
            if is_nic?(device)
                nic[:net_name]  = device.backing.network.name
                nic[:net_ref]   = device.backing.network._ref
                nic[:pg_type]   = VCenterDriver::Network.get_network_type(device)
                nics << nic
            end
        end
        return nics
    end

    #  Checks if a RbVmomi::VIM::VirtualDevice is a disk or a cdrom
    def is_disk_or_cdrom?(device)
        is_disk  = !(device.class.ancestors.index(RbVmomi::VIM::VirtualDisk)).nil?
        is_cdrom = !(device.class.ancestors.index(RbVmomi::VIM::VirtualCdrom)).nil?
        is_disk || is_cdrom
    end

    #  Checks if a RbVmomi::VIM::VirtualDevice is a disk or an iso file
    def is_disk_or_iso?(device)
        is_disk  = !(device.class.ancestors.index(RbVmomi::VIM::VirtualDisk)).nil?
        is_iso = device.backing.is_a? RbVmomi::VIM::VirtualCdromIsoBackingInfo
        is_disk || is_iso
    end

    #  Checks if a RbVmomi::VIM::VirtualDevice is a disk
    def is_disk?(device)
        !(device.class.ancestors.index(RbVmomi::VIM::VirtualDisk)).nil?
    end

    #  Checks if a RbVmomi::VIM::VirtualDevice is a network interface
    def is_nic?(device)
        !device.class.ancestors.index(RbVmomi::VIM::VirtualEthernetCard).nil?
    end

    # @return RbVmomi::VIM::ResourcePool, first resource pool in cluster
    def get_rp
        self['runtime.host.parent.resourcePool']
    end

    def to_one_template(template, cluster_ref, cluster_name, has_nics_and_disks, rp, rp_list, vcenter_uuid, vcenter_instance_name, dc_name)

        template_ref  = template['_ref']
        template_name = template["name"]

        one_tmp = {}
        one_tmp[:name]                  = "[#{vcenter_instance_name} - #{dc_name}] #{template_name} - #{cluster_name}"
        one_tmp[:template_name]         = template_name
        one_tmp[:vcenter_ccr_ref]       = cluster_ref
        one_tmp[:vcenter_ref]           = template_ref
        one_tmp[:vcenter_instance_uuid] = vcenter_uuid
        one_tmp[:cluster_name]          = cluster_name
        one_tmp[:rp]                    = rp
        one_tmp[:rp_list]               = rp_list
        one_tmp[:template]              = template
        one_tmp[:import_disks_and_nics] = has_nics_and_disks

        one_tmp[:one]                   = to_one(true, vcenter_uuid, cluster_ref, cluster_name, vcenter_instance_name, dc_name)
        return one_tmp
    end

    def vm_to_one(vm_name)

        str = "NAME   = \"#{vm_name}\"\n"\
              "CPU    = \"#{@vm_info["config.hardware.numCPU"]}\"\n"\
              "vCPU   = \"#{@vm_info["config.hardware.numCPU"]}\"\n"\
              "MEMORY = \"#{@vm_info["config.hardware.memoryMB"]}\"\n"\
              "HYPERVISOR = \"vcenter\"\n"\
              "SCHED_REQUIREMENTS=\"ID=\\\"#{@vm_info[:host_id]}\\\"\"\n"\
              "CONTEXT = [\n"\
              "    NETWORK = \"YES\",\n"\
              "    SSH_PUBLIC_KEY = \"$USER[SSH_PUBLIC_KEY]\"\n"\
              "]\n"\
              "VCENTER_INSTANCE_ID =\"#{@vm_info[:vc_uuid]}\"\n"\
              "VCENTER_CCR_REF =\"#{@vm_info[:cluster_ref]}\"\n"

        str << "IMPORT_VM_ID =\"#{self["_ref"]}\"\n"
        str << "IMPORT_STATE =\"#{@state}\"\n"

        vnc_port = nil
        keymap = nil

        @vm_info["config.extraConfig"].select do |xtra|
            if xtra[:key].downcase=="remotedisplay.vnc.port"
                vnc_port = xtra[:value]
            end

            if xtra[:key].downcase=="remotedisplay.vnc.keymap"
                keymap = xtra[:value]
            end
        end

        if !@vm_info["config.extraConfig"].empty?
            str << "GRAPHICS = [\n"\
                   "  TYPE     =\"vnc\",\n"
            str << "  PORT     =\"#{vnc_port}\",\n" if vnc_port
            str << "  KEYMAP   =\"#{keymap}\",\n" if keymap
            str << "  LISTEN   =\"0.0.0.0\"\n"
            str << "]\n"
        end

        if !@vm_info["config.annotation"] || @vm_info["config.annotation"].empty?
            str << "DESCRIPTION = \"vCenter Template imported by OpenNebula" \
                " from Cluster #{@vm_info["cluster_name"]}\"\n"
        else
            notes = @vm_info["config.annotation"].gsub("\\", "\\\\").gsub("\"", "\\\"")
            str << "DESCRIPTION = \"#{notes}\"\n"
        end

        case @vm_info["guest.guestFullName"]
            when /CentOS/i
                str << "LOGO=images/logos/centos.png\n"
            when /Debian/i
                str << "LOGO=images/logos/debian.png\n"
            when /Red Hat/i
                str << "LOGO=images/logos/redhat.png\n"
            when /Ubuntu/i
                str << "LOGO=images/logos/ubuntu.png\n"
            when /Windows XP/i
                str << "LOGO=images/logos/windowsxp.png\n"
            when /Windows/i
                str << "LOGO=images/logos/windows8.png\n"
            when /Linux/i
                str << "LOGO=images/logos/linux.png\n"
        end

        return str
    end

    def to_one(template=false, vc_uuid=nil, ccr_ref=nil, ccr_name=nil, vcenter_instance_name, dc_name)

        if !ccr_ref && !ccr_name
            cluster  = @item["runtime.host"].parent
            ccr_name = cluster.name
            ccr_ref  = cluster._ref
        end

        vc_uuid  = self["_connection.serviceContent.about.instanceUuid"] if !vc_uuid

        # Get info of the host where the VM/template is located
        host_id = nil
        one_host = VCenterDriver::VIHelper.find_by_ref(OpenNebula::HostPool,
                                                       "TEMPLATE/VCENTER_CCR_REF",
                                                       ccr_ref,
                                                       vc_uuid)

        num_cpu, memory, extraconfig, annotation, guest_fullname = @item.collect("config.hardware.numCPU","config.hardware.memoryMB","config.extraConfig","config.annotation","guest.guestFullName")
        host_id = one_host["ID"] if one_host

        name = ""
        if template
            name << "[#{vcenter_instance_name} - #{dc_name}] #{self["name"]} - #{ccr_name.tr(" ", "_")}"
        else
            name << "#{self["name"]} - #{ccr_name.tr(" ", "_")}"
        end

        str = "NAME   = \"#{name}\"\n"\
              "CPU    = \"#{num_cpu}\"\n"\
              "vCPU   = \"#{num_cpu}\"\n"\
              "MEMORY = \"#{memory}\"\n"\
              "HYPERVISOR = \"vcenter\"\n"\
              "SCHED_REQUIREMENTS=\"ID=\\\"#{host_id}\\\"\"\n"\
              "CONTEXT = [\n"\
              "    NETWORK = \"YES\",\n"\
              "    SSH_PUBLIC_KEY = \"$USER[SSH_PUBLIC_KEY]\"\n"\
              "]\n"\
              "VCENTER_INSTANCE_ID =\"#{vc_uuid}\"\n"

        if !template
            str << "IMPORT_VM_ID =\"#{self["_ref"]}\"\n"
            str << "IMPORT_STATE =\"#{@state}\"\n"
        end

        if template
            str << "VCENTER_TEMPLATE_REF =\"#{self['_ref']}\"\n"
            str << "VCENTER_CCR_REF =\"#{ccr_ref}\"\n"
        end

        vnc_port = nil
        keymap = nil

        if !template
            extraconfig.select do |xtra|

                if xtra[:key].downcase=="remotedisplay.vnc.port"
                    vnc_port = xtra[:value]
                end

                if xtra[:key].downcase=="remotedisplay.vnc.keymap"
                    keymap = xtra[:value]
                end
            end
        end

        if !extraconfig.empty?
            str << "GRAPHICS = [\n"\
                   "  TYPE     =\"vnc\",\n"
            str << "  PORT     =\"#{vnc_port}\",\n" if vnc_port
            str << "  KEYMAP   =\"#{keymap}\",\n" if keymap
            str << "  LISTEN   =\"0.0.0.0\"\n"
            str << "]\n"
        end

        if annotation.nil? || annotation.empty?
            str << "DESCRIPTION = \"vCenter Template imported by OpenNebula" \
                " from Cluster #{ccr_name}\"\n"
        else
            notes = annotation.gsub("\\", "\\\\").gsub("\"", "\\\"")
            str << "DESCRIPTION = \"#{notes}\"\n"
        end

        case guest_fullname
            when /CentOS/i
                str << "LOGO=images/logos/centos.png\n"
            when /Debian/i
                str << "LOGO=images/logos/debian.png\n"
            when /Red Hat/i
                str << "LOGO=images/logos/redhat.png\n"
            when /Ubuntu/i
                str << "LOGO=images/logos/ubuntu.png\n"
            when /Windows XP/i
                str << "LOGO=images/logos/windowsxp.png\n"
            when /Windows/i
                str << "LOGO=images/logos/windows8.png\n"
            when /Linux/i
                str << "LOGO=images/logos/linux.png\n"
        end

        return str
    end

    def self.get_xml_template(template, vcenter_uuid, vi_client, vcenter_instance_name=nil, dc_name=nil, rp_cache={})

        begin
            template_ccr  = template['runtime.host.parent']
            template_ccr_ref = template_ccr._ref
            template_ccr_name =template_ccr.name

            vcenter_instance_name = vi_client.vim.host if !vcenter_instance_name

            if !dc_name
                dc = get_dc
                dc_name = dc.item.name
            end
            # Check if template has nics or disks to be imported later
            has_nics_and_disks = true
            ##template["config.hardware.device"].each do |device|
            ##    if VCenterDriver::Storage.is_disk_or_iso?(device) ||
            ##    VCenterDriver::Network.is_nic?(device)
            ##        has_nics_and_disks = true
            ##        break
            ##    end
            ##end

            #Get resource pools

            if !rp_cache[template_ccr_name]
                tmp_cluster = VCenterDriver::ClusterComputeResource.new_from_ref(template_ccr_ref, vi_client)
                rp_list = tmp_cluster.get_resource_pool_list
                rp = ""
                if !rp_list.empty?
                    rp_name_list = []
                    rp_list.each do |rp_hash|
                        rp_name_list << rp_hash[:name]
                    end
                    rp =  "O|list|Which resource pool you want this VM to run in? "
                    rp << "|#{rp_name_list.join(",")}" #List of RP
                    rp << "|#{rp_name_list.first}" #Default RP
                end
                rp_cache[template_ccr_name] = {}
                rp_cache[template_ccr_name][:rp] = rp
                rp_cache[template_ccr_name][:rp_list] = rp_list
            end
            rp      = rp_cache[template_ccr_name][:rp]
            rp_list = rp_cache[template_ccr_name][:rp_list]

            object = template.to_one_template(template,
                                            template_ccr_ref,
                                            template_ccr_name,
                                            has_nics_and_disks,
                                            rp,
                                            rp_list,
                                            vcenter_uuid,
                                            vcenter_instance_name,
                                            dc_name)

            return object

        rescue
            return nil
        end
    end

    # TODO check with uuid
    def self.new_from_ref(ref, vi_client)
        self.new(RbVmomi::VIM::VirtualMachine.new(vi_client.vim, ref), vi_client)
    end

end

class VirtualMachine < Template
    VM_PREFIX_DEFAULT = "one-$i-"

    POLL_ATTRIBUTE    = OpenNebula::VirtualMachine::Driver::POLL_ATTRIBUTE
    VM_STATE          = OpenNebula::VirtualMachine::Driver::VM_STATE

    VM_SHUTDOWN_TIMEOUT = 600 #10 minutes til poweroff hard

    attr_accessor :item

    attr_accessor :vm_info

    include Memoize

    def initialize(item=nil, vi_client=nil)
        @item = item
        @vi_client = vi_client
        @locking = true
        @vm_info = nil
    end

    ############################################################################
    ############################################################################

    # Attributes that must be defined when the VM does not exist in vCenter
    attr_accessor :vi_client

    # these have their own getter (if they aren't set, we can set them
    # dynamically)
    attr_writer :one_item
    attr_writer :host
    attr_writer :target_ds_ref

    ############################################################################
    ############################################################################

    # The OpenNebula VM
    # @return OpenNebula::VirtualMachine or XMLElement
    def one_item
        if !@one_item
            vm_id = get_vm_id

            raise "Unable to find vm_id." if vm_id.nil?

            @one_item = VIHelper.one_item(OpenNebula::VirtualMachine, vm_id)
        end

        @one_item
    end

    # The OpenNebula host
    # @return OpenNebula::Host or XMLElement
    def host
        if @host.nil?
            if one_item.nil?
                raise "'one_item' must be previously set to be able to " <<
                      "access the OpenNebula host."
            end

            host_id = one_item["HISTORY_RECORDS/HISTORY[last()]/HID"]
            raise "No valid host_id found." if host_id.nil?

            @host = VIHelper.one_item(OpenNebula::Host, host_id)
        end

        @host
    end

    # Target Datastore VMware reference getter
    # @return
    def target_ds_ref
        if @target_ds_ref.nil?
            if one_item.nil?
                raise "'one_item' must be previously set to be able to " <<
                      "access the target Datastore."
            end

            target_ds_id = one_item["HISTORY_RECORDS/HISTORY[last()]/DS_ID"]
            raise "No valid target_ds_id found." if target_ds_id.nil?

            target_ds = VCenterDriver::VIHelper.one_item(OpenNebula::Datastore,
                                                         target_ds_id)

            @target_ds_ref = target_ds['TEMPLATE/VCENTER_DS_REF']
        end

        @target_ds_ref
    end

    # Cached cluster
    # @return ClusterComputeResource
    def cluster
        if @cluster.nil?
            ccr_ref = host['TEMPLATE/VCENTER_CCR_REF']
            @cluster = ClusterComputeResource.new_from_ref(ccr_ref, vi_client)
        end

        @cluster
    end

    ############################################################################
    ############################################################################

    # @return Boolean whether the VM exists in vCenter
    def is_new?
        !get_vm_id
    end

    # @return String the vm_id stored in vCenter
    def get_vm_id
        vm_ref = self['_ref']
        return nil if !vm_ref

        vc_uuid = get_vcenter_instance_uuid

        one_vm = VCenterDriver::VIHelper.find_by_ref(OpenNebula::VirtualMachinePool,
                                                     "DEPLOY_ID",
                                                     vm_ref,
                                                     vc_uuid)
        return nil if !one_vm

        return one_vm["ID"]
    end

    def get_vcenter_instance_uuid
        @vi_client.vim.serviceContent.about.instanceUuid
    end

    def get_unmanaged_keys
        unmanaged_keys = {}
        @item.config.extraConfig.each do |val|
             if val[:key].include?("opennebula.disk")
                 unmanaged_keys[val[:key]] = val[:value]
             end
        end
        return unmanaged_keys
    end

    ############################################################################
    # Getters
    ############################################################################

    # @return RbVmomi::VIM::ResourcePool
    def get_rp

        req_rp = one_item['VCENTER_RESOURCE_POOL'] ||
                 one_item['USER_TEMPLATE/VCENTER_RESOURCE_POOL']

        #Get ref for req_rp
        rp_list    = cluster.get_resource_pool_list
        req_rp_ref = rp_list.select { |rp| rp[:name] == req_rp }.first[:ref] rescue nil

        if vi_client.rp_confined?
            if req_rp_ref && req_rp_ref != vi_client.rp._ref
                raise "Available resource pool [#{vi_client.rp.name}] in host"\
                      " does not match requested resource pool"\
                      " [#{req_rp}]"
            end

            return vi_client.rp
        else
            if req_rp_ref
                rps = cluster.resource_pools.select{|r| r._ref == req_rp_ref }

                if rps.empty?
                    raise "No matching resource pool found (#{req_rp})."
                else
                    return rps.first
                end
            else
                return cluster['resourcePool']
            end
        end
    end

    # @return RbVmomi::VIM::Datastore or nil
    def get_ds
        ##req_ds = one_item['USER_TEMPLATE/VCENTER_DS_REF']
        ##TODO SCHED_DS_REQUIREMENTS??
        current_ds_id  = one_item["HISTORY_RECORDS/HISTORY[last()]/DS_ID"]
        current_ds     = VCenterDriver::VIHelper.one_item(OpenNebula::Datastore, current_ds_id)
        current_ds_ref = current_ds['TEMPLATE/VCENTER_DS_REF']

        if current_ds_ref
            dc = cluster.get_dc

            ds_folder = dc.datastore_folder
            ds = ds_folder.get(current_ds_ref)
            ds_item = ds.item rescue nil

            return ds_item
        else
            return nil
        end
    end

    # StorageResouceManager reference
    def get_sm
        self['_connection.serviceContent.storageResourceManager']
    end

    # @return Customization or nil
    def get_customization
        xpath = "USER_TEMPLATE/VCENTER_CUSTOMIZATION_SPEC"
        customization_spec = one_item[xpath]

        if customization_spec.nil?
            return nil
        end

        begin
            custom_spec = vi_client.vim
                            .serviceContent
                            .customizationSpecManager
                            .GetCustomizationSpec(:name => customization.text)

            if custom_spec && (spec = custom_spec.spec)
                return spec
            else
                raise "Error getting customization spec"
            end
        rescue
            raise "Customization spec '#{customization.text}' not found"
        end
    end

    # @return VCenterDriver::Datastore datastore where the disk will live under
    def get_effective_ds(disk)
        if disk["PERSISTENT"] == "YES"
            ds_ref = disk["VCENTER_DS_REF"]
        else
            ds_ref = target_ds_ref

            if ds_ref.nil?
                raise "target_ds_ref must be defined on this object."
            end
        end

        VCenterDriver::Storage.new_from_ref(ds_ref, vi_client)
    end

    # @return String vcenter name
    def get_vcenter_name
        vm_prefix = host['TEMPLATE/VM_PREFIX']
        vm_prefix = VM_PREFIX_DEFAULT if vm_prefix.nil? || vm_prefix.empty?
        vm_prefix.gsub!("$i", one_item['ID'])

        vm_prefix + one_item['NAME']
    end

    ############################################################################
    # Create and reconfigure VM related methods
    ############################################################################

    # This function creates a new VM from the @one_item XML and returns the
    # VMware ref
    # @param one_item OpenNebula::VirtualMachine
    # @param vi_client VCenterDriver::VIClient
    # @return String vmware ref
    def clone_vm(one_item, vi_client)
        @one_item = one_item
        @vi_client = vi_client

        vcenter_name = get_vcenter_name

        vc_template_ref = one_item['USER_TEMPLATE/VCENTER_TEMPLATE_REF']
        vc_template = RbVmomi::VIM::VirtualMachine(vi_client.vim, vc_template_ref)

        ds = get_ds

        # Default disk move type (Full Clone)
        disk_move_type = :moveAllDiskBackingsAndDisallowSharing

        if ds.instance_of? RbVmomi::VIM::Datastore
            use_linked_clones = one_item['USER_TEMPLATE/VCENTER_LINKED_CLONES']
            if use_linked_clones && use_linked_clones.downcase == "yes"
                # Check if all disks in template has delta disks
                disks = vc_template.config
                                .hardware.device.grep(RbVmomi::VIM::VirtualDisk)

                disks_no_delta = disks.select { |d| d.backing.parent == nil }

                # Can use linked clones if all disks have delta disks
                if (disks_no_delta.size == 0)
                    disk_move_type = :moveChildMostDiskBacking
                end
            end
        end

        spec_hash = spec_hash_clone(disk_move_type)

        clone_spec = RbVmomi::VIM.VirtualMachineCloneSpec(spec_hash)

        # Specify vm folder in vSpere's VM and Templates view F#4823
        vcenter_vm_folder = nil
        vcenter_vm_folder = one_item["USER_TEMPLATE/VCENTER_VM_FOLDER"]
        vcenter_vm_folder_object = nil
        dc = cluster.get_dc
        if !!vcenter_vm_folder && !vcenter_vm_folder.empty?
            vcenter_vm_folder_object = dc.item.find_folder(vcenter_vm_folder)
        end
        vcenter_vm_folder_object = vc_template.parent if vcenter_vm_folder_object.nil?

        if ds.instance_of? RbVmomi::VIM::StoragePod
            # VM is cloned using Storage Resource Manager for StoragePods
            begin
                vm = storagepod_clonevm_task(vc_template, vcenter_name,
                                             clone_spec, ds, vcenter_vm_folder_object, dc)
            rescue Exception => e
                raise "Cannot clone VM Template to StoragePod: #{e.message}"
            end
        else
            vm = nil
            begin
                vm = vc_template.CloneVM_Task(
                    :folder => vcenter_vm_folder_object,
                    :name   => vcenter_name,
                    :spec   => clone_spec).wait_for_completion
            rescue Exception => e
                if !e.message.start_with?('DuplicateName')
                    raise "Cannot clone VM Template: #{e.message}\n#{e.backtrace}"
                end

                vm_folder = dc.vm_folder
                vm_folder.fetch!
                vm = vm_folder.items
                        .select{|k,v| v.item.name == vcenter_name}
                        .values.first.item rescue nil

                if vm
                    # Detach all persistent disks to avoid accidental destruction
                    detach_persistent_disks(vm)

                    vm.Destroy_Task.wait_for_completion
                    vm = vc_template.CloneVM_Task(
                        :folder => vcenter_vm_folder_object,
                        :name   => vcenter_name,
                        :spec   => clone_spec).wait_for_completion
                else
                    raise "Cannot clone VM Template"
                end
            end
        end
        # @item is populated
        @item = vm

        return self['_ref']
    end


    def storagepod_clonevm_task(vc_template, vcenter_name, clone_spec, storpod, vcenter_vm_folder_object, dc)

        storage_manager = vc_template
                            ._connection.serviceContent.storageResourceManager

        storage_spec = RbVmomi::VIM.StoragePlacementSpec(
            type: 'clone',
            cloneName: vcenter_name,
            folder: vcenter_vm_folder_object,
            podSelectionSpec: RbVmomi::VIM.StorageDrsPodSelectionSpec(storagePod: storpod),
            vm: vc_template,
            cloneSpec: clone_spec
        )

        # Query a storage placement recommendation
        result = storage_manager
                    .RecommendDatastores(storageSpec: storage_spec) rescue nil

        raise "Could not get placement specification for StoragePod" if result.nil?

        if !result.respond_to?(:recommendations) || result.recommendations.size == 0
            raise "Could not get placement specification for StoragePod"
        end

        # Get recommendation key to be applied
        key = result.recommendations.first.key ||= ''
        raise "Missing Datastore recommendation for StoragePod" if key.empty?

        begin
            apply_sr = storage_manager
                            .ApplyStorageDrsRecommendation_Task(key: [key])
                            .wait_for_completion
            return apply_sr.vm
        rescue Exception => e
            if !e.message.start_with?('DuplicateName')
                raise "Cannot clone VM Template: #{e.message}\n#{e.backtrace}"
            end

            # The VM already exists, try to find the vm
            vm_folder = dc.vm_folder
            vm_folder.fetch!
            vm = vm_folder.items
                    .select{|k,v| v.item.name == vcenter_name}
                    .values.first.item rescue nil

            if vm

                begin
                    # Detach all persistent disks to avoid accidental destruction
                    detach_persistent_disks(vm)

                    # Destroy the VM with any disks still attached to it
                    vm.Destroy_Task.wait_for_completion

                    # Query a storage placement recommendation
                    result = storage_manager.RecommendDatastores(storageSpec: storage_spec) rescue nil

                    raise "Could not get placement specification for StoragePod" if result.nil?

                    if !result.respond_to?(:recommendations) || result.recommendations.size == 0
                        raise "Could not get placement specification for StoragePod"
                    end

                    # Get recommendation key to be applied
                    key = result.recommendations.first.key ||= ''
                    raise "Missing Datastore recommendation for StoragePod" if key.empty?

                    apply_sr = storage_manager
                            .ApplyStorageDrsRecommendation_Task(key: [key])
                            .wait_for_completion
                    return apply_sr.vm
                rescue Exception => e
                   raise "Failure applying recommendation while cloning VM: #{e.message}"
                end
            end
        end
    end

    # @return clone parameters spec hash
    def spec_hash_clone(disk_move_type)
        # Relocate spec
        relocate_spec_params = {}

        relocate_spec_params[:pool] = get_rp
        relocate_spec_params[:diskMoveType] = disk_move_type

        ds = get_ds

        relocate_spec_params[:datastore] = ds if ds.instance_of? Datastore

        relocate_spec = RbVmomi::VIM.VirtualMachineRelocateSpec(
                                                         relocate_spec_params)

        # Running flag - prevents spurious poweroff states in the VM
        running_flag = [{ :key => "opennebula.vm.running", :value => "no"}]

        running_flag_spec = RbVmomi::VIM.VirtualMachineConfigSpec(
            { :extraConfig => running_flag }
        )

        clone_parameters = {
            :location => relocate_spec,
            :powerOn  => false,
            :template => false,
            :config   => running_flag_spec
        }

        cs = get_customization
        clone_parameters[:customization] = cs if cs

        clone_parameters
    end

    def reference_unmanaged_devices(template_ref)

        extraconfig   = []
        device_change = []

        # Get unmanaged disks in OpenNebula's VM template
        xpath = "TEMPLATE/DISK[OPENNEBULA_MANAGED=\"NO\" or OPENNEBULA_MANAGED=\"no\"]"
        unmanaged_disks = one_item.retrieve_xmlelements(xpath)

        if !unmanaged_disks.empty?

            # Get vcenter VM disks to know real path of cloned disk
            vcenter_disks = get_vcenter_disks

            # Create an array with the paths of the disks in vcenter template
            template = VCenterDriver::Template.new_from_ref(template_ref, vi_client)
            template_disks = template.get_vcenter_disks
            template_disks_vector = []
            template_disks.each do |d|
                template_disks_vector << d[:path_wo_ds]
            end

            # Try to find index of disks in template disks
            unmanaged_disks.each do |unmanaged_disk|
                index = template_disks_vector.index(unmanaged_disk["SOURCE"])
                if index
                    reference = {}
                    reference[:key]   = "opennebula.disk.#{unmanaged_disk["DISK_ID"]}"
                    reference[:value] = "#{vcenter_disks[index][:key]}"
                    extraconfig << reference
                end
            end
        end

        # Add info for existing nics in template in vm xml
        xpath = "TEMPLATE/NIC[OPENNEBULA_MANAGED=\"NO\" or OPENNEBULA_MANAGED=\"no\"]"
        unmanaged_nics = one_item.retrieve_xmlelements(xpath)

        if !unmanaged_nics.empty?
            index = 0
            self["config.hardware.device"].each_with_index do |device|
                if is_nic?(device)
                    # Edit capacity setting new size in KB
                    device.macAddress = unmanaged_nics[index]["MAC"]
                    device_change << { :device => device, :operation => :edit }
                    index += 1
                end
            end
        end

        # Save in extraconfig the key for unmanaged disks
        if !extraconfig.empty? || !device_change.empty?
            spec = {}
            spec[:extraConfig]  = extraconfig if !extraconfig.empty?
            spec[:deviceChange] = device_change if !device_change.empty?
            @item.ReconfigVM_Task(:spec => spec).wait_for_completion
        end
    end

    def resize_unmanaged_disks
        resize_hash = {}
        disks = []

        unmanaged_keys = get_unmanaged_keys
        vc_disks = get_vcenter_disks

        # Look for unmanaged disks with original size changed
        xpath = "TEMPLATE/DISK[(OPENNEBULA_MANAGED=\"NO\" or OPENNEBULA_MANAGED=\"no\") and boolean(ORIGINAL_SIZE) and ORIGINAL_SIZE != SIZE]"
        unmanaged_resized_disks = one_item.retrieve_xmlelements(xpath)

        return if unmanaged_resized_disks.empty?

        unmanaged_resized_disks.each do |disk|
            vc_disks.each do |vcenter_disk|
                if unmanaged_keys.key?("opennebula.disk.#{disk["DISK_ID"]}")
                    device_key = unmanaged_keys["opennebula.disk.#{disk["DISK_ID"]}"].to_i

                    if device_key == vcenter_disk[:key].to_i

                        break if disk["SIZE"].to_i <= disk["ORIGINAL_SIZE"].to_i

                        # Edit capacity setting new size in KB
                        d = vcenter_disk[:device]
                        d.capacityInKB = disk["SIZE"].to_i * 1024
                        disks <<   { :device => d, :operation => :edit }
                        break
                    end
                end
            end
        end

        if !disks.empty?
            resize_hash[:deviceChange] = disks
            @item.ReconfigVM_Task(:spec => resize_hash).wait_for_completion
        end
    end

    def create_storagedrs_disks(device_change_spod, device_change_spod_ids)

        sm = get_sm
        disk_locator = []
        extra_config = []

        device_change_spod.each do |device_spec|
            disk_locator << RbVmomi::VIM.PodDiskLocator(diskId: device_spec[:device].key)
        end

        spec = {}
        spec[:deviceChange] = device_change_spod

        # Disk locator is required for AddDisk
        vmpod_hash = {}
        vmpod_hash[:storagePod] = get_ds
        vmpod_hash[:disk] = disk_locator
        vmpod_config = RbVmomi::VIM::VmPodConfigForPlacement(vmpod_hash)

        # The storage pod selection requires initialize
        spod_hash = {}
        spod_hash[:initialVmConfig] = [ vmpod_config ]
        spod_select = RbVmomi::VIM::StorageDrsPodSelectionSpec(spod_hash)
        storage_spec = RbVmomi::VIM.StoragePlacementSpec(
            type: :reconfigure,
            podSelectionSpec: spod_select,
            vm: self['_ref'],
            configSpec: spec
        )

        # Query a storage placement recommendation
        result = sm.RecommendDatastores(storageSpec: storage_spec) rescue nil

        raise "Could not get placement specification for StoragePod" if result.nil?

        if !result.respond_to?(:recommendations) || result.recommendations.size == 0
            raise "Could not get placement specification for StoragePod"
        end

        # Get recommendation key to be applied
        key = result.recommendations.first.key ||= ''
        raise "Missing Datastore recommendation for StoragePod" if key.empty?

        # Apply recommendation
        sm.ApplyStorageDrsRecommendation_Task(key: [key]).wait_for_completion

        # Set references in opennebula.disk elements
        device_change_spod.each do |device_spec|
            unit_number    = device_spec[:device].unitNumber
            controller_key = device_spec[:device].controllerKey
            key            = get_vcenter_disk_key(unit_number, controller_key)
            disk_id        = device_change_spod_ids["#{controller_key}-#{unit_number}"]
            reference      = {}
            reference[:key]   = "opennebula.disk.#{disk_id}"
            reference[:value] = key.to_s
            extra_config << reference
        end

        extra_config
    end


    def reconfigure
        extraconfig   = []
        device_change = []

        # Unmanaged keys
        unmanaged_keys = get_unmanaged_keys

        # Get disk devices in vm
        vc_disks = get_vcenter_disks

        # Get an array with disk paths in OpenNebula's vm template
        disks_in_onevm_vector = disks_in_onevm(unmanaged_keys, vc_disks)

        # As the original template may have been modified in OpenNebula
        # but not in vcenter, we must detach disks that are in vcenter
        # but not in OpenNebula's vm template
        if is_new?
            device_change, extra_config = device_detach_disks(disks_in_onevm_vector, unmanaged_keys, vc_disks)
            if !device_change.empty?
                spec_hash = {}
                spec_hash[:deviceChange] = device_change if !device_change.empty?
                spec_hash[:extraConfig] = extra_config  if !extra_config.empty?

                # Reconfigure for disks detached from original template
                spec = RbVmomi::VIM.VirtualMachineConfigSpec(spec_hash)
                @item.ReconfigVM_Task(:spec => spec).wait_for_completion

                # Get disk devices in vm again after reconfigure
                vc_disks = get_vcenter_disks
            end
        end

        # Now reconfigure disks, nics and extraconfig for the VM
        device_change = []

        # get token and context
        extraconfig += extraconfig_context

        # vnc configuration (for config_array hash)
        extraconfig += extraconfig_vnc

        # Set CPU, memory and extraconfig
        num_cpus = one_item["TEMPLATE/VCPU"] || 1

        spec_hash = {
            :numCPUs      => num_cpus.to_i,
            :memoryMB     => one_item["TEMPLATE/MEMORY"],
            :extraConfig  => extraconfig
        }

        # prepare pg and sw for vcenter nics if any
        configure_vcenter_network

        # device_change hash (nics)
        device_change += device_change_nics

        # track pg or dpg in case they must be removed
        vcenter_uuid = get_vcenter_instance_uuid
        networks = VCenterDriver::Network.vcenter_networks_to_be_removed(device_change_nics, vcenter_uuid)

        # Now attach disks that are in OpenNebula's template but not in vcenter
        # e.g those that has been attached in poweroff
        device_change_ds, device_change_spod, device_change_spod_ids = device_attach_disks(disks_in_onevm_vector, vc_disks)
        device_change += device_change_ds

        # Create volatile disks in StorageDRS if any
        if !device_change_spod.empty?
            spec_hash[:extraConfig] = create_storagedrs_disks(device_change_spod, device_change_spod_ids)
        end

        # Common reconfigure task
        spec_hash[:deviceChange] = device_change
        spec = RbVmomi::VIM.VirtualMachineConfigSpec(spec_hash)
        @item.ReconfigVM_Task(:spec => spec).wait_for_completion

        #Remove switch and pg if NICs detached in poweroff
        remove_poweroff_detached_vcenter_nets(networks) if !networks.empty?
    end

    def extraconfig_context
        context_text = "# Context variables generated by OpenNebula\n"
        one_item.each('TEMPLATE/CONTEXT/*') do |context_element|
            # next if !context_element.text
            context_text += context_element.name + "='" +
                            context_element.text.gsub("'", "\\'") + "'\n"
        end

        # token
        token = File.read(File.join(VAR_LOCATION,
                        'vms',
                        one_item['ID'],
                        'token.txt')).chomp rescue nil

        context_text += "ONEGATE_TOKEN='#{token}'\n" if token

        # context_text
        [
            { :key => "guestinfo.opennebula.context",
              :value => Base64.encode64(context_text) }
        ]
    end

    def extraconfig_vnc
        if one_item["TEMPLATE/GRAPHICS"]
            vnc_port   = one_item["TEMPLATE/GRAPHICS/PORT"]
            vnc_listen = one_item["TEMPLATE/GRAPHICS/LISTEN"] || "0.0.0.0"
            vnc_keymap = one_item["TEMPLATE/GRAPHICS/KEYMAP"]

            conf = [ {:key => "remotedisplay.vnc.enabled",:value => "TRUE"},
                    {:key => "remotedisplay.vnc.port",   :value => vnc_port},
                    {:key => "remotedisplay.vnc.ip",     :value => vnc_listen}]

            conf += [{:key => "remotedisplay.vnc.keymap",
                            :value => vnc_keymap}] if vnc_keymap

            conf
        else
            conf = []
        end
    end

    def device_change_nics
        # Final list of changes to be applied in vCenter
        device_change = []

        # Hash of interfaces from the OpenNebula xml
        nics_in_template = {}
        xpath = "TEMPLATE/NIC"
        one_item.each(xpath) { |nic|
            nics_in_template[nic["MAC"]] = nic
        }

        # Check nics in VM
        self["config.hardware.device"].each do |dv|
            if is_nic?(dv)
                if nics_in_template.key?(dv.macAddress)
                    # Remove nic that is already in the XML to avoid duplicate
                    nics_in_template.delete(dv.macAddress)
                else
                    # B4897 - It was detached in poweroff, remove it from VM
                    device_change << {
                        :operation => :remove,
                        :device    => dv
                    }
                end
            end
        end

        # Attach new nics (nics_in_template now contains only the interfaces
        # not present in the VM in vCenter)
        nics_in_template.each do |key, nic|
            device_change << calculate_add_nic_spec(nic)
        end

        return device_change
    end

    # Regenerate context when devices are hot plugged (reconfigure)
    def regenerate_context
        spec_hash = { :extraConfig  => extraconfig_context }
        spec = RbVmomi::VIM.VirtualMachineConfigSpec(spec_hash)

        begin
            @item.ReconfigVM_Task(:spec => spec).wait_for_completion
        rescue Exception => e
            raise "Cannot create snapshot for VM: #{e.message}\n#{e.backtrace}"
        end
    end

    # Returns an array of actions to be included in :deviceChange
    def calculate_add_nic_spec(nic)

        #TODO include VCENTER_NET_MODEL usage it should be in one_item
        mac       = nic["MAC"]
        pg_name   = nic["BRIDGE"]
        model     = nic["VCENTER_NET_MODEL"] || VCenterDriver::VIHelper.get_default("VM/TEMPLATE/NIC/MODEL")
        vnet_ref  = nic["VCENTER_NET_REF"]
        backing   = nil

        limit_in  = nic["INBOUND_PEAK_BW"] || VCenterDriver::VIHelper.get_default("VM/TEMPLATE/NIC/INBOUND_PEAK_BW")
        limit_out = nic["OUTBOUND_PEAK_BW"]
        limit     = nil

        if limit_in && limit_out
            limit=([limit_in.to_i, limit_out.to_i].min / 1024) * 8
        end

        rsrv_in  = nic["INBOUND_AVG_BW"]
        rsrv_out = nic["OUTBOUND_AVG_BW"]
        rsrv     = nil

        if rsrv_in || rsrv_out
            rsrv=([rsrv_in.to_i, rsrv_out.to_i].min / 1024) * 8
        end

        network = self["runtime.host"].network.select do |n|
            n._ref == vnet_ref || n.name == pg_name
        end

        network = network.first

        card_num = 1 # start in one, we want the next avaliable id

        @item["config.hardware.device"].each do |dv|
            card_num += 1 if is_nic?(dv)
        end

        nic_card = case model
                        when "virtuale1000", "e1000"
                            RbVmomi::VIM::VirtualE1000
                        when "virtuale1000e", "e1000e"
                            RbVmomi::VIM::VirtualE1000e
                        when "virtualpcnet32", "pcnet32"
                            RbVmomi::VIM::VirtualPCNet32
                        when "virtualsriovethernetcard", "sriovethernetcard"
                            RbVmomi::VIM::VirtualSriovEthernetCard
                        when "virtualvmxnetm", "vmxnetm"
                            RbVmomi::VIM::VirtualVmxnetm
                        when "virtualvmxnet2", "vmnet2"
                            RbVmomi::VIM::VirtualVmxnet2
                        when "virtualvmxnet3", "vmxnet3"
                            RbVmomi::VIM::VirtualVmxnet3
                        else # If none matches, use VirtualE1000
                            RbVmomi::VIM::VirtualE1000
                   end

        if network.class == RbVmomi::VIM::Network
            backing = RbVmomi::VIM.VirtualEthernetCardNetworkBackingInfo(
                        :deviceName => pg_name,
                        :network    => network)
        else
            port    = RbVmomi::VIM::DistributedVirtualSwitchPortConnection(
                        :switchUuid =>
                                network.config.distributedVirtualSwitch.uuid,
                        :portgroupKey => network.key)
            backing =
              RbVmomi::VIM.VirtualEthernetCardDistributedVirtualPortBackingInfo(
                 :port => port)
        end

        card_spec = {
            :key => 0,
            :deviceInfo => {
                :label => "net" + card_num.to_s,
                :summary => pg_name
            },
            :backing     => backing,
            :addressType => mac ? 'manual' : 'generated',
            :macAddress  => mac
        }

        if (limit || rsrv) && (limit > 0)
            ra_spec = {}
            rsrv = limit if rsrv > limit
            ra_spec[:limit] = limit if limit
            ra_spec[:reservation] = rsrv if rsrv
            ra_spec[:share] =  RbVmomi::VIM.SharesInfo({
                    :level => RbVmomi::VIM.SharesLevel("normal"),
                    :shares => 0
                })
            card_spec[:resourceAllocation] =
               RbVmomi::VIM.VirtualEthernetCardResourceAllocation(ra_spec)
        end

        {
            :operation => :add,
            :device    => nic_card.new(card_spec)
        }
    end

    def vcenter_standard_network(nic, esx_host, vcenter_uuid)
        pg_name     = nic["BRIDGE"]
        switch_name = nic["VCENTER_SWITCH_NAME"]
        pnics       = nic["PHYDEV"] || nil
        mtu         = nic["MTU"] || 1500
        vlan_id     = nic["VLAN_ID"] || nic["AUTOMATIC_VLAN_ID"] || 0
        num_ports   = nic["VCENTER_SWITCH_NPORTS"] || 128

        begin
            esx_host.lock # Exclusive lock for ESX host operation

            pnics_available = nil
            pnics_available = esx_host.get_available_pnics if pnics

            # Get port group if it exists
            pg = esx_host.pg_exists(pg_name)

            # Disallow changes of switch name for existing pg
            if pg && esx_host.pg_changes_sw?(pg, switch_name)
                raise "The port group's switch name can not be modified"\
                    " for OpenNebula's virtual network, please revert"\
                    " it back in its definition and create a different"\
                    " virtual network instead."
            end

            if !pg
                # Get standard switch if it exists
                vs = esx_host.vss_exists(switch_name)

                if !vs
                    switch_name = esx_host.create_vss(switch_name, pnics, num_ports, mtu, pnics_available)
                else
                    #Update switch
                    esx_host.update_vss(vs, switch_name, pnics, num_ports, mtu)
                end

                vnet_ref     = esx_host.create_pg(pg_name, switch_name, vlan_id)

                # We must update XML so the VCENTER_NET_REF is set
                one_vnet = VCenterDriver::VIHelper.one_item(OpenNebula::VirtualNetwork, nic["NETWORK_ID"])
                one_vnet.delete_element("TEMPLATE/VCENTER_NET_REF") if one_vnet["TEMPLATE/VCENTER_NET_REF"]
                one_vnet.delete_element("TEMPLATE/VCENTER_INSTANCE_ID") if one_vnet["TEMPLATE/VCENTER_INSTANCE_ID"]
                rc = one_vnet.update("VCENTER_NET_REF = \"#{vnet_ref}\"\n"\
                                        "VCENTER_INSTANCE_ID = \"#{vcenter_uuid}\"", true)
                if OpenNebula.is_error?(rc)
                    raise "Could not update VCENTER_NET_REF for virtual network"
                end
                one_vnet.info

            else
                # pg exist, update
                esx_host.update_pg(pg, switch_name, vlan_id)

                # update switch if needed
                vs = esx_host.vss_exists(switch_name)
                esx_host.update_vss(vs, switch_name, pnics, num_ports, mtu) if vs
            end

        rescue Exception => e
            esx_host.network_rollback
            raise e
        ensure
            esx_host.unlock if esx_host # Remove lock
        end
    end

    def vcenter_distributed_network(nic, esx_host, vcenter_uuid, dc, net_folder)
        pg_name     = nic["BRIDGE"]
        switch_name = nic["VCENTER_SWITCH_NAME"]
        pnics       = nic["PHYDEV"] || nil
        mtu         = nic["MTU"] || 1500
        vlan_id     = nic["VLAN_ID"] || nic["AUTOMATIC_VLAN_ID"] || 0
        num_ports   = nic["VCENTER_SWITCH_NPORTS"] || 8

        begin
            # Get distributed port group if it exists
            dpg = dc.dpg_exists(pg_name, net_folder)

            # Disallow changes of switch name for existing pg
            if dpg && dc.pg_changes_sw?(dpg, switch_name)
                raise "The port group's switch name can not be modified"\
                    " for OpenNebula's virtual network, please revert"\
                    " it back in its definition and create a different"\
                    " virtual network instead."
            end

            if !dpg
                # Get distributed virtual switch if it exists
                dvs = dc.dvs_exists(switch_name, net_folder)

                if !dvs
                    dvs = dc.create_dvs(switch_name, pnics, mtu)
                else
                    #Update switch
                    dc.update_dvs(dvs, pnics, mtu)
                end

                vnet_ref = dc.create_dpg(dvs, pg_name, vlan_id, num_ports)

                # We must connect portgroup to current host
                begin
                    esx_host.lock

                    pnics_available = nil
                    pnics_available = esx_host.get_available_pnics if pnics

                    proxy_switch = esx_host.proxy_switch_exists(switch_name)

                    esx_host.assign_proxy_switch(dvs, switch_name, pnics, pnics_available)

                rescue Exception => e
                    raise e
                ensure
                    esx_host.unlock if esx_host # Remove lock
                end

                # We must update XML so the VCENTER_NET_REF is set
                one_vnet = VCenterDriver::VIHelper.one_item(OpenNebula::VirtualNetwork, nic["NETWORK_ID"])
                one_vnet.delete_element("TEMPLATE/VCENTER_NET_REF") if one_vnet["TEMPLATE/VCENTER_NET_REF"]
                one_vnet.delete_element("TEMPLATE/VCENTER_INSTANCE_ID") if one_vnet["TEMPLATE/VCENTER_INSTANCE_ID"]
                rc = one_vnet.update("VCENTER_NET_REF = \"#{vnet_ref}\"\n"\
                                        "VCENTER_INSTANCE_ID = \"#{vcenter_uuid}\"", true)
                if OpenNebula.is_error?(rc)
                    raise "Could not update VCENTER_NET_REF for virtual network"
                end
                one_vnet.info
            else
                # pg exist, dpg update
                dc.update_dpg(dpg, vlan_id, num_ports)

                # update switch if needed
                dvs = dc.dvs_exists(switch_name, net_folder)
                dc.update_dvs(dvs, pnics, mtu) if dvs

                # We must connect or update portgroup to current host (proxyswitch)
                begin
                    esx_host.lock

                    pnics_available = nil
                    pnics_available = esx_host.get_available_pnics if pnics

                    proxy_switch = esx_host.proxy_switch_exists(switch_name)
                    esx_host.assign_proxy_switch(dvs, switch_name, pnics, pnics_available)

                rescue Exception => e
                    raise e
                ensure
                    esx_host.unlock if esx_host # Remove lock
                end
            end

        rescue Exception => e
            dc.network_rollback
            raise e
        end

    end

    def configure_vcenter_network(nic_xml=nil)
        nics = []
        if nic_xml
            nics << nic_xml
        else
            nics = one_item.retrieve_xmlelements("TEMPLATE/NIC[VN_MAD=\"vcenter\"]")
        end

        return if nics.empty?

        vcenter_uuid = get_vcenter_instance_uuid
        esx_host = VCenterDriver::ESXHost.new_from_ref(self['runtime'].host._ref, vi_client)

        nics.each do |nic|

            if nic["VCENTER_INSTANCE_ID"] && nic["VCENTER_INSTANCE_ID"] != vcenter_uuid
                raise "The virtual network is not assigned to the right vcenter server, create a different virtual network instead"
            end

            if nic["VCENTER_PORTGROUP_TYPE"] == "Port Group"
                vcenter_standard_network(nic, esx_host, vcenter_uuid)
            end

            if nic["VCENTER_PORTGROUP_TYPE"] == "Distributed Port Group"
                dc = cluster.get_dc # Get datacenter
                begin
                    dc.lock

                    # Explore network folder in search of dpg and dvs
                    net_folder = dc.network_folder
                    net_folder.fetch!

                    vcenter_distributed_network(nic, esx_host, vcenter_uuid, dc, net_folder)
                rescue Exception => e
                    #TODO rollback
                    raise e
                ensure
                    dc.unlock if dc
                end
            end
        end
    end

    # Add NIC to VM
    def attach_nic
        spec_hash = {}
        nic = nil

        # Extract nic from driver action
        nic = one_item.retrieve_xmlelements("TEMPLATE/NIC[ATTACH='YES']").first

        begin
            # Prepare network for vcenter networks
            configure_vcenter_network(nic) if nic["VN_MAD"] == "vcenter"

            # A new NIC requires a vcenter spec
            attach_nic_array = []
            attach_nic_array << calculate_add_nic_spec(nic)
            spec_hash[:deviceChange] = attach_nic_array if !attach_nic_array.empty?

            # Reconfigure VM
            spec = RbVmomi::VIM.VirtualMachineConfigSpec(spec_hash)

            @item.ReconfigVM_Task(:spec => spec).wait_for_completion
        rescue Exception => e
            raise "Cannot attach NIC to VM: #{e.message}\n#{e.backtrace}"
        end

    end

    # Detach NIC from VM
    def detach_nic
        spec_hash = {}
        nic = nil

        # Extract nic from driver action
        nic = one_item.retrieve_xmlelements("TEMPLATE/NIC[ATTACH='YES']").first
        mac = nic["MAC"]

        # Get VM nic element if it has a device with that mac
        nic_device = @item["config.hardware.device"].find do |device|
            is_nic?(device) && (device.macAddress ==  mac)
        end rescue nil

        return if nic_device.nil? #Silently ignore if nic is not found

        # Remove NIC from VM in the ReconfigVM_Task
        spec_hash[:deviceChange] = [
                :operation => :remove,
                :device => nic_device ]

        begin
            @item.ReconfigVM_Task(:spec => spec_hash).wait_for_completion
        rescue Exception => e
            raise "Cannot detach NIC from VM: #{e.message}\n#{e.backtrace}"
        end
    end

    # Detach all nics useful when removing pg and sw so they're not in use
    def detach_all_nics
        spec_hash = {}
        device_change = []

        @item["config.hardware.device"].each do |device|
            if is_nic?(device)
                device_change << {:operation => :remove, :device => device}
            end
        end

        # Remove NIC from VM in the ReconfigVM_Task
        spec_hash[:deviceChange] = device_change

        begin
            @item.ReconfigVM_Task(:spec => spec_hash).wait_for_completion
        rescue Exception => e
            raise "Cannot detach all NICs from VM: #{e.message}\n#{e.backtrace}"
        end
    end

    def get_device_filename_and_ds_from_key(key, vc_disks)
        device = vc_disks.select{ |d| d[:key].to_i == key.to_i}.first rescue nil
        return device
    end

    def disks_in_onevm(unmanaged_keys, vc_disks)
        onevm_disks_vector = []

        disks = one_item.retrieve_xmlelements("TEMPLATE/DISK")
        disks.each do |disk|
            if unmanaged_keys.key?("opennebula.disk.#{disk["DISK_ID"]}")
                device_key = unmanaged_keys["opennebula.disk.#{disk["DISK_ID"]}"].to_i
                disk_hash = get_device_filename_and_ds_from_key(device_key, vc_disks)
                onevm_disks_vector << disk_hash[:path_wo_ds] if disk_hash
                next
            end

            img_name  = VCenterDriver::FileHelper.get_img_name(disk, one_item['ID'], self['name'])
            onevm_disks_vector << "#{img_name}"
        end

        return onevm_disks_vector
    end

    def device_attach_disks(onevm_disks_vector, vc_disks)

        disks = one_item.retrieve_xmlelements("TEMPLATE/DISK")

        vc_disks.each do |d|
            index = onevm_disks_vector.index(d[:path_wo_ds])
            if index
                disks.delete_at(index)
                onevm_disks_vector.delete_at(index)
            end
        end

        return [],[],{} if disks.empty?

        attach_disk_array = []
        attach_spod_array = []
        attach_spod_disk_info = {}

        position = 0
        disks.each do |disk|
            storpod = disk["VCENTER_DS_REF"].start_with?('group-')
            if storpod
                spec = calculate_add_disk_spec(disk, position)
                attach_spod_array << spec
                unit_ctrl = "#{spec[:device].controllerKey}-#{spec[:device].unitNumber}"
                attach_spod_disk_info[unit_ctrl] = disk["DISK_ID"]
            else
                attach_disk_array << calculate_add_disk_spec(disk, position)
            end

            position += 1
        end

        return attach_disk_array, attach_spod_array, attach_spod_disk_info
    end

    def device_detach_disks(onevm_disks_vector, unmanaged_keys, vc_disks)
        detach_disk_array = []
        extra_config      = []
        ipool = VCenterDriver::VIHelper.one_pool(OpenNebula::ImagePool)
        if ipool.respond_to?(:message)
            raise "Could not get OpenNebula ImagePool: #{ipool.message}"
        end

        vc_disks.each do |d|
            if !onevm_disks_vector.index(d[:path_wo_ds])

                # If disk to be detached is not persistent detach and destroy it
                persistent = VCenterDriver::VIHelper.find_persistent_image_by_source(d[:path_wo_ds], ipool)
                if !persistent
                    detach_disk_array << {
                        :fileOperation => :destroy,
                        :operation => :remove,
                        :device    => d[:device]
                    }
                end

                # Remove reference opennebula.disk if exist
                unmanaged_keys.each do |key, value|
                    if value.to_i == d[:key].to_i
                        reference = {}
                        reference[:key]   = key
                        reference[:value] = ""
                        extra_config << reference
                        break
                    end
                end
            end
        end

        return detach_disk_array, extra_config
    end

    # Attach DISK to VM (hotplug)
    def attach_disk
        # TODO position? and disk size for volatile?

        spec_hash = {}
        disk = nil
        device_change = []

        # Extract unmanaged_keys
        unmanaged_keys = get_unmanaged_keys
        vc_disks = get_vcenter_disks

        # Extract disk from driver action
        disk = one_item.retrieve_xmlelements("TEMPLATE/DISK[ATTACH='YES']").first

        # Check if we're dealing with a StoragePod SYSTEM ds
        storpod = disk["VCENTER_DS_REF"].start_with?('group-')

        # Check if disk being attached is already connected to the VM
        raise "DISK is already connected to VM" if disk_attached_to_vm(disk, unmanaged_keys, vc_disks)

        # Generate vCenter spec and reconfigure VM
        device_change << calculate_add_disk_spec(disk)
        raise "Could not generate DISK spec" if device_change.empty?

        spec_hash[:deviceChange] = device_change
        spec = RbVmomi::VIM.VirtualMachineConfigSpec(spec_hash)

        begin
            if storpod
                #Ask for StorageDRS recommendation to reconfigure VM (AddDisk)
                sm = get_sm

                # Disk id is -1 as I don't know what disk id is going to be set
                disk_locator = [ RbVmomi::VIM.PodDiskLocator(diskId: -1) ]

                # Disk locator is required for AddDisk
                vmpod_hash = {}
                vmpod_hash[:storagePod] = get_ds
                vmpod_hash[:disk] = disk_locator
                vmpod_config = RbVmomi::VIM::VmPodConfigForPlacement(vmpod_hash)

                # The storage pod selection requires initialize
                spod_hash = {}
                spod_hash[:initialVmConfig] = [ vmpod_config ]
                spod_select = RbVmomi::VIM::StorageDrsPodSelectionSpec(spod_hash)
                storage_spec = RbVmomi::VIM.StoragePlacementSpec(
                    type: :reconfigure,
                    podSelectionSpec: spod_select,
                    vm: self['_ref'],
                    configSpec: spec
                )

                # Query a storage placement recommendation
                result = sm.RecommendDatastores(storageSpec: storage_spec) rescue nil

                raise "Could not get placement specification for StoragePod" if result.nil?

                if !result.respond_to?(:recommendations) || result.recommendations.size == 0
                    raise "Could not get placement specification for StoragePod"
                end

                # Get recommendation key to be applied
                key = result.recommendations.first.key ||= ''
                raise "Missing Datastore recommendation for StoragePod" if key.empty?

                # Apply recommendation
                sm.ApplyStorageDrsRecommendation_Task(key: [key]).wait_for_completion

                # Add the key for the volatile disk to the unmanaged opennebula.disk.id variables
                unit_number    = spec_hash[:deviceChange][0][:device].unitNumber
                controller_key = spec_hash[:deviceChange][0][:device].controllerKey
                key = get_vcenter_disk_key(unit_number, controller_key)
                spec_hash = {}
                reference = {}
                reference[:key]   = "opennebula.disk.#{disk["DISK_ID"]}"
                reference[:value] = key.to_s
                spec_hash[:extraConfig] = [ reference ]
                @item.ReconfigVM_Task(:spec => spec_hash).wait_for_completion
            else
                @item.ReconfigVM_Task(:spec => spec).wait_for_completion
            end
        rescue Exception => e
            raise "Cannot attach DISK to VM: #{e.message}\n#{e.backtrace}"
        end
    end

    # Detach persistent disks to avoid incidental destruction
    def detach_persistent_disks(vm)
        spec_hash = {}
        spec_hash[:deviceChange] = []
        ipool = VCenterDriver::VIHelper.one_pool(OpenNebula::ImagePool)
        if ipool.respond_to?(:message)
            raise "Could not get OpenNebula ImagePool: #{ipool.message}"
        end

        vm.config.hardware.device.each do |disk|
            if is_disk_or_cdrom?(disk)
                # Let's try to find if disks is persistent
                source = disk.backing.fileName.sub(/^\[(.*?)\] /, "")
                persistent = VCenterDriver::VIHelper.find_persistent_image_by_source(source, ipool)
                if persistent
                    spec_hash[:deviceChange] << {
                        :operation => :remove,
                        :device => disk
                    }
                end
            end

        end

        return nil if spec_hash[:deviceChange].empty?

        begin
            vm.ReconfigVM_Task(:spec => spec_hash).wait_for_completion
        rescue Exception => e
            raise "Cannot detach all DISKs from VM: #{e.message}\n#{e.backtrace}"
        end
    end


    # Detach DISK from VM
    def detach_disk(disk)
        spec_hash = {}
        img_path = ""
        ds_ref = nil

        # Extract unmanaged disk keys
        unmanaged_keys = get_unmanaged_keys
        vc_disks = get_vcenter_disks

        # Get vcenter device to be detached and remove if found
        device = disk_attached_to_vm(disk, unmanaged_keys, vc_disks)

        if device
            img_path << device[:path_wo_ds]

            if unmanaged_keys.key?("opennebula.disk.#{disk["DISK_ID"]}")
                reference = {}
                reference[:key]   = "opennebula.disk.#{disk["DISK_ID"]}"
                reference[:value] = ""
                spec_hash[:extraConfig] = [ reference ]
            end

            ds_ref = device[:datastore]._ref

            # Generate vCenter spec and reconfigure VM
            spec_hash[:deviceChange] = [{
                :operation => :remove,
                :device => device[:device]
            }]

            begin
                @item.ReconfigVM_Task(:spec => spec_hash).wait_for_completion
            rescue Exception => e
                raise "Cannot detach DISK from VM: #{e.message}\n#{e.backtrace}"
            end
        end

        return ds_ref, img_path
    end

    # Get vcenter device representing DISK object (hotplug)
    def disk_attached_to_vm(disk, unmanaged_keys, vc_disks)

        img_name = ""
        device_found = nil
        disk_id = disk["DISK_ID"]

        vc_disks.each do |d|
            # Check if we are dealing with the unmanaged disks present in the template when cloned

            if unmanaged_keys.key?("opennebula.disk.#{disk_id}") && d[:key] == unmanaged_keys["opennebula.disk.#{disk_id}"].to_i
                device_found = d
                break
            end

            # Alright let's see if we can find other devices only with the expected image name
            img_name  = VCenterDriver::FileHelper.get_img_name(disk, one_item['ID'], self['name'])
            if d[:path_wo_ds] == "#{img_name}"
                device_found = d
                break
            end
        end

        return device_found
    end

    def calculate_add_disk_spec(disk, position=0)
        img_name = VCenterDriver::FileHelper.get_img_name(disk, one_item['ID'], self['name'])
        type     = disk["TYPE"]
        size_kb  = disk["SIZE"].to_i * 1024

        if type == "CDROM"
            # CDROM drive will be found in the IMAGE DS
            ds_ref   = disk["VCENTER_DS_REF"]
            ds       = VCenterDriver::Storage.new_from_ref(ds_ref, @vi_client)
            ds_name  = ds['name']

            # CDROM can only be added when the VM is in poweroff state
            vmdk_backing = RbVmomi::VIM::VirtualCdromIsoBackingInfo(
                :datastore => ds.item,
                :fileName  => "[#{ds_name}] #{img_name}"
            )

            if @item["summary.runtime.powerState"] != "poweredOff"
                raise "The CDROM image can only be added as an IDE device "\
                      "when the VM is in the powered off state"
            end

            controller, unit_number = find_free_ide_controller(position)

            device = RbVmomi::VIM::VirtualCdrom(
                :backing       => vmdk_backing,
                :key           => -1,
                :controllerKey => controller.key,
                :unitNumber    => unit_number,

                :connectable => RbVmomi::VIM::VirtualDeviceConnectInfo(
                    :startConnected    => true,
                    :connected         => true,
                    :allowGuestControl => true
                )
            )

            return {
                :operation => :add,
                :device => device
            }

        else
            # TYPE is regular disk (not CDROM)

            controller, unit_number = find_free_controller(position)

            storpod = disk["VCENTER_DS_REF"].start_with?('group-')
            if storpod
                vmdk_backing = RbVmomi::VIM::VirtualDiskFlatVer2BackingInfo(
                  :diskMode  => 'persistent',
                  :fileName  => ""
                )
            else
                ds           = get_effective_ds(disk)
                ds_name      = ds['name']
                vmdk_backing = RbVmomi::VIM::VirtualDiskFlatVer2BackingInfo(
                  :datastore => ds.item,
                  :diskMode  => 'persistent',
                  :fileName  => "[#{ds_name}] #{img_name}"
                )
            end

            device = RbVmomi::VIM::VirtualDisk(
              :backing       => vmdk_backing,
              :capacityInKB  => size_kb,
              :controllerKey => controller.key,
              :key           => (-1 - position),
              :unitNumber    => unit_number
            )

            config = {
               :operation => :add,
               :device    => device
            }

            # For StorageDRS vCenter must create the file
            config[:fileOperation] = :create if storpod

            return config
        end
    end

    def has_snapshots?
        self['rootSnapshot'] && !self['rootSnapshot'].empty?
    end

    def instantiated_as_persistent?
        begin
            !!one_item["TEMPLATE/CLONING_TEMPLATE_ID"]
        rescue
            return false #one_item may not be retrieved if deploy_id hasn't been set
        end
    end

    def remove_poweroff_detached_vcenter_nets(networks)
        esx_host = VCenterDriver::ESXHost.new_from_ref(@item.runtime.host._ref, vi_client)
        dc = cluster.get_dc # Get datacenter

        networks.each do |pg_name, one|

            if one["TEMPLATE/VCENTER_PORTGROUP_TYPE"] == "Port Group"
                begin
                    esx_host.lock # Exclusive lock for ESX host operation

                    next if !esx_host.pg_exists(pg_name)
                    swname = esx_host.remove_pg(pg_name)
                    next if !swname

                    # We must update XML so the VCENTER_NET_REF is unset
                    VCenterDriver::Network.remove_net_ref(one["ID"])

                    next if !esx_host.vss_exists(swname)
                    swname = esx_host.remove_vss(swname)

                rescue Exception => e
                    raise e
                ensure
                    esx_host.unlock if esx_host # Remove lock
                end
            end

            if one["TEMPLATE/VCENTER_PORTGROUP_TYPE"] == "Distributed Port Group"
                begin
                    dc.lock

                    # Explore network folder in search of dpg and dvs
                    net_folder = dc.network_folder
                    net_folder.fetch!

                    # Get distributed port group if it exists
                    dpg = dc.dpg_exists(pg_name, net_folder)
                    dc.remove_dpg(dpg) if dpg

                    # We must update XML so the VCENTER_NET_REF is unset
                    VCenterDriver::Network.remove_net_ref(one["ID"])

                    # Get distributed virtual switch and try to remove it
                    switch_name =  one["TEMPLATE/VCENTER_SWITCH_NAME"]
                    dvs = dc.dvs_exists(switch_name, net_folder)
                    dc.remove_dvs(dvs) if dvs

                rescue Exception => e
                    dc.network_rollback
                    raise e
                ensure
                    dc.unlock if dc
                end
            end
        end
    end

    def find_free_ide_controller(position=0)

        free_ide_controllers = []
        ide_schema           = {}

        used_numbers      = []
        available_numbers = []

        @item["config.hardware.device"].each do |dev|
            if dev.is_a? RbVmomi::VIM::VirtualIDEController
                if ide_schema[dev.key].nil?
                    ide_schema[dev.key] = {}
                end

                ide_schema[dev.key][:device] = dev
            end

            next if dev.class != RbVmomi::VIM::VirtualCdrom
            used_numbers << dev.unitNumber
        end

        2.times do |ide_id|
            available_numbers << ide_id if used_numbers.grep(ide_id).length <= 0
        end

        ide_schema.keys.each do |controller|
            free_ide_controllers << ide_schema[controller][:device].deviceInfo.label
        end

        if free_ide_controllers.empty?
            raise "There are no free IDE controllers to connect this CDROM device"
        end

        available_controller_label = free_ide_controllers[0]

        controller = nil

        @item['config.hardware.device'].each do |device|
            if device.deviceInfo.label == available_controller_label
                controller = device
                break
            end
        end

        new_unit_number = available_numbers.sort[position]

        return controller, new_unit_number
    end

    def find_free_controller(position=0)
        free_scsi_controllers = []
        scsi_schema           = {}

        used_numbers      = []
        available_numbers = []

        @item["config.hardware.device"].each do |dev|
            if dev.is_a? RbVmomi::VIM::VirtualSCSIController
                if scsi_schema[dev.key].nil?
                    scsi_schema[dev.key] = {}
                end

                used_numbers << dev.scsiCtlrUnitNumber
                scsi_schema[dev.key][:device] = dev
            end

            next if dev.class != RbVmomi::VIM::VirtualDisk
            used_numbers << dev.unitNumber
        end

        15.times do |scsi_id|
            available_numbers << scsi_id if used_numbers.grep(scsi_id).length <= 0
        end

        scsi_schema.keys.each do |controller|
            free_scsi_controllers << scsi_schema[controller][:device].deviceInfo.label
        end

        if free_scsi_controllers.length > 0
            available_controller_label = free_scsi_controllers[0]
        else
            add_new_scsi(scsi_schema)
            return find_free_controller
        end

        controller = nil

        @item['config.hardware.device'].each do |device|
            if device.deviceInfo.label == available_controller_label
                controller = device
                break
            end
        end

        new_unit_number = available_numbers.sort[position]

        return controller, new_unit_number
    end

    def add_new_scsi(scsi_schema)
        controller = nil

        if scsi_schema.keys.length >= 4
            raise "Cannot add a new controller, maximum is 4."
        end

        scsi_key    = 0
        scsi_number = 0

        if scsi_schema.keys.length > 0 && scsi_schema.keys.length < 4
            scsi_key    = scsi_schema.keys.sort[-1] + 1
            scsi_number = scsi_schema[scsi_schema.keys.sort[-1]][:device].busNumber + 1
        end

        controller_device = RbVmomi::VIM::VirtualLsiLogicController(
            :key       => scsi_key,
            :busNumber => scsi_number,
            :sharedBus => :noSharing
        )

        device_config_spec = RbVmomi::VIM::VirtualDeviceConfigSpec(
            :device    => controller_device,
            :operation => :add
        )

        vm_config_spec = RbVmomi::VIM::VirtualMachineConfigSpec(
            :deviceChange => [device_config_spec]
        )

        @item.ReconfigVM_Task(:spec => vm_config_spec).wait_for_completion

        @item["config.hardware.device"].each do |device|
            if device.class == RbVmomi::VIM::VirtualLsiLogicController &&
                device.key == scsi_key

                controller = device.deviceInfo.label
            end
        end

        return controller
    end

    # Create a snapshot for the VM
    def create_snapshot(snap_id, snap_name)
        snapshot_hash = {
            :name        => snap_id,
            :description => "OpenNebula Snapshot: #{snap_name}",
            :memory      => true,
            :quiesce     => true
        }

        vcenter_version = @vi_client.vim.serviceContent.about.apiVersion rescue nil

        if vcenter_version != "5.5"
            begin
                @item.CreateSnapshot_Task(snapshot_hash).wait_for_completion
            rescue Exception => e
                raise "Cannot create snapshot for VM: #{e.message}\n#{e.backtrace}"
            end
        else
            # B#5045 - If vcenter is 5.5 the snapshot may take longer than
            # 15 minutes and it does not report that it has finished using
            # wait_for_completion so we use an active wait instead with a
            # timeout of 1440 minutes = 24 hours
            @item.CreateSnapshot_Task(snapshot_hash)

            snapshot_created  = false
            elapsed_minutes   = 0

            until snapshot_created || elapsed_minutes == 1440
                if !!@item['snapshot']
                    current_snapshot = @item['snapshot.currentSnapshot'] rescue nil
                    snapshot_found = find_snapshot_in_list(@item['snapshot.rootSnapshotList'], snap_id)
                    snapshot_created = !!snapshot_found && !!current_snapshot && current_snapshot._ref == snapshot_found._ref
                end
                sleep(60)
                elapsed_minutes += 1
            end
        end

        return snap_id
    end

    # Revert to a VM snapshot
    def revert_snapshot(snap_id)

        snapshot_list = self["snapshot.rootSnapshotList"]
        snapshot = find_snapshot_in_list(snapshot_list, snap_id)

        return nil if !snapshot

        begin
            revert_snapshot_hash = { :_this => snapshot }
            snapshot.RevertToSnapshot_Task(revert_snapshot_hash).wait_for_completion
        rescue Exception => e
            raise "Cannot revert snapshot of VM: #{e.message}\n#{e.backtrace}"
        end
    end

    # Delete VM snapshot
    def delete_snapshot(snap_id)

        snapshot_list = self["snapshot.rootSnapshotList"]
        snapshot = find_snapshot_in_list(snapshot_list, snap_id)

        return nil if !snapshot

        begin
            delete_snapshot_hash = {
                :_this => snapshot,
                :removeChildren => false
            }
            snapshot.RemoveSnapshot_Task(delete_snapshot_hash).wait_for_completion
        rescue Exception => e
            raise "Cannot delete snapshot of VM: #{e.message}\n#{e.backtrace}"
        end
    end

    def find_snapshot_in_list(list, snap_id)
        list.each do |i|
            if i.name == snap_id.to_s
                return i.snapshot
            elsif !i.childSnapshotList.empty?
                snap = find_snapshot_in_list(i.childSnapshotList, snap_id)
                return snap if snap
            end
        end rescue nil

        nil
    end

    ############################################################################
    # actions
    ############################################################################

    def shutdown
        begin
            @item.ShutdownGuest
            # Check if VM has been powered off
            (0..VM_SHUTDOWN_TIMEOUT).each do
                break if @item.runtime.powerState == "poweredOff"
                sleep 1
            end
        rescue
            # Ignore ShutdownGuest exceptions, maybe VM hasn't openvm tools
        end

        # If VM hasn't been powered off, do it now
        if @item.runtime.powerState != "poweredOff"
            poweroff_hard
        end
    end

    def destroy
        @item.Destroy_Task.wait_for_completion
    end

    def mark_as_template
        @item.MarkAsTemplate
    end

    def reset
        @item.ResetVM_Task.wait_for_completion
    end

    def suspend
        @item.SuspendVM_Task.wait_for_completion
    end

    def reboot
        @item.RebootGuest
    end

    def poweron
        @item.PowerOnVM_Task.wait_for_completion
    end

    def is_powered_on?
        return @item.runtime.powerState == "poweredOn"
    end

    def poweroff_hard
        @item.PowerOffVM_Task.wait_for_completion
    end

    def remove_all_snapshots
        @item.RemoveAllSnapshots_Task.wait_for_completion
    end

    def set_running(state)
        value = state ? "yes" : "no"

        config_array = [
            { :key => "opennebula.vm.running", :value => value }
        ]
        spec = RbVmomi::VIM.VirtualMachineConfigSpec(
            { :extraConfig => config_array }
        )

        @item.ReconfigVM_Task(:spec => spec).wait_for_completion
    end

    ############################################################################
    # monitoring
    ############################################################################

    # monitor function used when VMM poll action is called
    def monitor_poll_vm
        reset_monitor

        @state = state_to_c(self["summary.runtime.powerState"])

        if @state != VM_STATE[:active]
            reset_monitor
            return
        end

        cpuMhz = self["runtime.host.summary.hardware.cpuMhz"].to_f

        @monitor[:used_memory] = self["summary.quickStats.hostMemoryUsage"] * 1024

        used_cpu = self["summary.quickStats.overallCpuUsage"].to_f / cpuMhz
        used_cpu = (used_cpu * 100).to_s
        @monitor[:used_cpu]  = sprintf('%.2f', used_cpu).to_s

        # Check for negative values
        @monitor[:used_memory] = 0 if @monitor[:used_memory].to_i < 0
        @monitor[:used_cpu]    = 0 if @monitor[:used_cpu].to_i < 0

        guest_ip_addresses = []
        self["guest.net"].each do |net|
            net.ipConfig.ipAddress.each do |ip|
                guest_ip_addresses << ip.ipAddress
            end if net.ipConfig && net.ipConfig.ipAddress
        end if self["guest.net"]

        @guest_ip_addresses = guest_ip_addresses.join(',')

        pm = self['_connection'].serviceInstance.content.perfManager

        provider = pm.provider_summary(@item)

        refresh_rate = provider.refreshRate

        if get_vm_id
            stats = []

            if (one_item["MONITORING/LAST_MON"] && one_item["MONITORING/LAST_MON"].to_i != 0 )
                #Real time data stores max 1 hour. 1 minute has 3 samples
                interval = (Time.now.to_i - one_item["MONITORING/LAST_MON"].to_i)

                #If last poll was more than hour ago get 3 minutes,
                #else calculate how many samples since last poll
                samples =  interval > 3600 ? 9 : (interval / refresh_rate) + 1
                max_samples = samples > 0 ? samples : 1

                stats = pm.retrieve_stats(
                    [@item],
                    ['net.transmitted','net.bytesRx','net.bytesTx','net.received',
                    'virtualDisk.numberReadAveraged','virtualDisk.numberWriteAveraged',
                    'virtualDisk.read','virtualDisk.write'],
                    {interval:refresh_rate, max_samples: max_samples}
                )
            else
                # First poll, get at least latest 3 minutes = 9 samples
                stats = pm.retrieve_stats(
                    [@item],
                    ['net.transmitted','net.bytesRx','net.bytesTx','net.received',
                    'virtualDisk.numberReadAveraged','virtualDisk.numberWriteAveraged',
                    'virtualDisk.read','virtualDisk.write'],
                    {interval:refresh_rate, max_samples: 9}
                )
            end

            if !stats.empty? && !stats.first[1][:metrics].empty?
                metrics = stats.first[1][:metrics]

                nettx_kbpersec = 0
                if metrics['net.transmitted']
                    metrics['net.transmitted'].each { |sample|
                        nettx_kbpersec += sample if sample > 0
                    }
                end

                netrx_kbpersec = 0
                if metrics['net.bytesRx']
                    metrics['net.bytesRx'].each { |sample|
                        netrx_kbpersec += sample if sample > 0
                    }
                end

                read_kbpersec = 0
                if metrics['virtualDisk.read']
                    metrics['virtualDisk.read'].each { |sample|
                        read_kbpersec += sample if sample > 0
                    }
                end

                read_iops = 0
                if metrics['virtualDisk.numberReadAveraged']
                    metrics['virtualDisk.numberReadAveraged'].each { |sample|
                        read_iops += sample if sample > 0
                    }
                end

                write_kbpersec = 0
                if metrics['virtualDisk.write']
                    metrics['virtualDisk.write'].each { |sample|
                        write_kbpersec += sample if sample > 0
                    }
                end

                write_iops = 0
                if metrics['virtualDisk.numberWriteAveraged']
                    metrics['virtualDisk.numberWriteAveraged'].each { |sample|
                        write_iops += sample if sample > 0
                    }
                end

                # Accumulate values if present
                previous_nettx = @one_item && @one_item["MONITORING/NETTX"] ? @one_item["MONITORING/NETTX"].to_i : 0
                previous_netrx = @one_item && @one_item["MONITORING/NETRX"] ? @one_item["MONITORING/NETRX"].to_i : 0
                previous_diskrdiops = @one_item && @one_item["MONITORING/DISKRDIOPS"] ? @one_item["MONITORING/DISKRDIOPS"].to_i : 0
                previous_diskwriops = @one_item && @one_item["MONITORING/DISKWRIOPS"] ? @one_item["MONITORING/DISKWRIOPS"].to_i : 0
                previous_diskrdbytes = @one_item && @one_item["MONITORING/DISKRDBYTES"] ? @one_item["MONITORING/DISKRDBYTES"].to_i : 0
                previous_diskwrbytes = @one_item && @one_item["MONITORING/DISKWRBYTES"] ? @one_item["MONITORING/DISKWRBYTES"].to_i : 0

                @monitor[:nettx] = previous_nettx + (nettx_kbpersec * 1024 * refresh_rate).to_i
                @monitor[:netrx] = previous_netrx + (netrx_kbpersec * 1024 * refresh_rate).to_i

                @monitor[:diskrdiops]  = previous_diskrdiops + read_iops
                @monitor[:diskwriops]  = previous_diskwriops + write_iops
                @monitor[:diskrdbytes] = previous_diskrdbytes + (read_kbpersec * 1024 * refresh_rate).to_i
                @monitor[:diskwrbytes] = previous_diskwrbytes + (write_kbpersec * 1024 * refresh_rate).to_i
            end
        end
    end

    # monitor function used when poll action is called for all vms
    def monitor(stats)

        reset_monitor

        refresh_rate = 20 #20 seconds between samples (realtime)

        @state = state_to_c(@vm_info["summary.runtime.powerState"])

        return if @state != VM_STATE[:active]

        cpuMhz =  @vm_info[:esx_host_cpu]

        @monitor[:used_memory] = @vm_info["summary.quickStats.hostMemoryUsage"].to_i * 1024

        used_cpu = @vm_info["summary.quickStats.overallCpuUsage"].to_f / cpuMhz
        used_cpu = (used_cpu * 100).to_s
        @monitor[:used_cpu]  = sprintf('%.2f', used_cpu).to_s

        # Check for negative values
        @monitor[:used_memory] = 0 if @monitor[:used_memory].to_i < 0
        @monitor[:used_cpu]    = 0 if @monitor[:used_cpu].to_i < 0

        guest_ip_addresses = []
        @vm_info["guest.net"].each do |net|
            net.ipConfig.ipAddress.each do |ip|
                guest_ip_addresses << ip.ipAddress
            end if net.ipConfig && net.ipConfig.ipAddress
        end if self["guest.net"]

        @guest_ip_addresses = guest_ip_addresses.join(',')

        if stats.key?(@item)
            metrics = stats[@item][:metrics]

            nettx_kbpersec = 0
            if metrics['net.transmitted']
                metrics['net.transmitted'].each { |sample|
                    nettx_kbpersec += sample if sample > 0
                }
            end

            netrx_kbpersec = 0
            if metrics['net.bytesRx']
                metrics['net.bytesRx'].each { |sample|
                    netrx_kbpersec += sample if sample > 0
                }
            end

            read_kbpersec = 0
            if metrics['virtualDisk.read']
                metrics['virtualDisk.read'].each { |sample|
                    read_kbpersec += sample if sample > 0
                }
            end

            read_iops = 0
            if metrics['virtualDisk.numberReadAveraged']
                metrics['virtualDisk.numberReadAveraged'].each { |sample|
                    read_iops += sample if sample > 0
                }
            end

            write_kbpersec = 0
            if metrics['virtualDisk.write']
                metrics['virtualDisk.write'].each { |sample|
                    write_kbpersec += sample if sample > 0
                }
            end

            write_iops = 0
            if metrics['virtualDisk.numberWriteAveraged']
                metrics['virtualDisk.numberWriteAveraged'].each { |sample|
                    write_iops += sample if sample > 0
                }
            end

            # Accumulate values if present
            previous_nettx = @one_item && @one_item["MONITORING/NETTX"] ? @one_item["MONITORING/NETTX"].to_i : 0
            previous_netrx = @one_item && @one_item["MONITORING/NETRX"] ? @one_item["MONITORING/NETRX"].to_i : 0
            previous_diskrdiops = @one_item && @one_item["MONITORING/DISKRDIOPS"] ? @one_item["MONITORING/DISKRDIOPS"].to_i : 0
            previous_diskwriops = @one_item && @one_item["MONITORING/DISKWRIOPS"] ? @one_item["MONITORING/DISKWRIOPS"].to_i : 0
            previous_diskrdbytes = @one_item && @one_item["MONITORING/DISKRDBYTES"] ? @one_item["MONITORING/DISKRDBYTES"].to_i : 0
            previous_diskwrbytes = @one_item && @one_item["MONITORING/DISKWRBYTES"] ? @one_item["MONITORING/DISKWRBYTES"].to_i : 0

            @monitor[:nettx] = previous_nettx + (nettx_kbpersec * 1024 * refresh_rate).to_i
            @monitor[:netrx] = previous_netrx + (netrx_kbpersec * 1024 * refresh_rate).to_i

            @monitor[:diskrdiops]  = previous_diskrdiops + read_iops
            @monitor[:diskwriops]  = previous_diskwriops + write_iops
            @monitor[:diskrdbytes] = previous_diskrdbytes + (read_kbpersec * 1024 * refresh_rate).to_i
            @monitor[:diskwrbytes] = previous_diskwrbytes + (write_kbpersec * 1024 * refresh_rate).to_i
        end
    end



    #  Generates a OpenNebula IM Driver valid string with the monitor info
    def info
        return 'STATE=d' if @state == 'd'

        guest_ip = @vm_info ? @vm_info["guest.ipAddress"] : self["guest.ipAddress"]

        used_cpu    = @monitor[:used_cpu]
        used_memory = @monitor[:used_memory]
        netrx       = @monitor[:netrx]
        nettx       = @monitor[:nettx]
        diskrdbytes = @monitor[:diskrdbytes]
        diskwrbytes = @monitor[:diskwrbytes]
        diskrdiops  = @monitor[:diskrdiops]
        diskwriops  = @monitor[:diskwriops]

        esx_host      = @vm_info ? @vm_info[:esx_host_name].to_s : self["runtime.host.name"].to_s
        guest_state   = @vm_info ? @vm_info["guest.guestState"].to_s : self["guest.guestState"].to_s
        vmware_tools  = @vm_info ? @vm_info["guest.toolsRunningStatus"].to_s : self["guest.toolsRunningStatus"].to_s
        vmtools_ver   = @vm_info ? @vm_info["guest.toolsVersion"].to_s :  self["guest.toolsVersion"].to_s
        vmtools_verst = @vm_info ? @vm_info["guest.toolsVersionStatus2"].to_s : vmtools_verst = self["guest.toolsVersionStatus2"].to_s

        if @vm_info
            rp_name   = @vm_info[:rp_list].select { |item| item[:ref] == @vm_info["resourcePool"]._ref}.first[:name] rescue ""
            rp_name   = "Resources" if rp_name.empty?
        else
            rp_name   = self["resourcePool"].name
        end

        str_info = ""

        str_info = "GUEST_IP=" << guest_ip.to_s << " " if guest_ip

        if @guest_ip_addresses && !@guest_ip_addresses.empty?
            str_info << "GUEST_IP_ADDRESSES=\"" << @guest_ip_addresses.to_s << "\" "
        end

        str_info << "#{POLL_ATTRIBUTE[:state]}="  << @state               << " "
        str_info << "#{POLL_ATTRIBUTE[:cpu]}="    << used_cpu.to_s        << " "
        str_info << "#{POLL_ATTRIBUTE[:memory]}=" << used_memory.to_s     << " "
        str_info << "#{POLL_ATTRIBUTE[:netrx]}="  << netrx.to_s           << " "
        str_info << "#{POLL_ATTRIBUTE[:nettx]}="  << nettx.to_s           << " "

        str_info << "DISKRDBYTES=" << diskrdbytes.to_s << " "
        str_info << "DISKWRBYTES=" << diskwrbytes.to_s << " "
        str_info << "DISKRDIOPS="  << diskrdiops.to_s  << " "
        str_info << "DISKWRIOPS="  << diskwriops.to_s  << " "

        str_info << "VCENTER_ESX_HOST=\""                 << esx_host        << "\" "
        str_info << "VCENTER_GUEST_STATE="                << guest_state     << " "
        str_info << "VCENTER_VMWARETOOLS_RUNNING_STATUS=" << vmware_tools    << " "
        str_info << "VCENTER_VMWARETOOLS_VERSION="        << vmtools_ver     << " "
        str_info << "VCENTER_VMWARETOOLS_VERSION_STATUS=" << vmtools_verst   << " "
        str_info << "VCENTER_RP_NAME=\""                  << rp_name << "\" "
    end

    def reset_monitor
        @monitor = {
            :used_cpu    => 0,
            :used_memory => 0,
            :netrx       => 0,
            :nettx       => 0,
            :diskrdbytes => 0,
            :diskwrbytes => 0,
            :diskrdiops  => 0,
            :diskwriops  => 0
        }
    end

    # Converts the VI string state to OpenNebula state convention
    # Guest states are:
    # - poweredOff   The virtual machine is currently powered off.
    # - poweredOn    The virtual machine is currently powered on.
    # - suspended    The virtual machine is currently suspended.
    def state_to_c(state)
        case state
            when 'poweredOn'
                VM_STATE[:active]
            when 'suspended'
                VM_STATE[:paused]
            when 'poweredOff'
                VM_STATE[:deleted]
            else
                VM_STATE[:unknown]
        end
    end

    # TODO check with uuid
    def self.new_from_ref(ref, vi_client)
        self.new(RbVmomi::VIM::VirtualMachine.new(vi_client.vim, ref), vi_client)
    end

end # class VirtualMachine

end # module VCenterDriver
