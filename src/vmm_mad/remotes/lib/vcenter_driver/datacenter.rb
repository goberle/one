module VCenterDriver
require 'set'
class DatacenterFolder
    attr_accessor :items

    def initialize(vi_client)
        @vi_client = vi_client
        @items = {}
    end

    ########################################################################
    # Builds a hash with Datacenter-Ref / Datacenter to be used as a cache
    # @return [Hash] in the form
    #   { dc_ref [Symbol] => Datacenter object }
    ########################################################################
    def fetch!
        VIClient.get_entities(@vi_client.vim.root, "Datacenter").each do |item|
            item_name = item._ref
            @items[item_name.to_sym] = Datacenter.new(item)
        end
    end

    ########################################################################
    # Returns a Datacenter. Uses the cache if available.
    # @param ref [Symbol] the vcenter ref
    # @return Datacenter
    ########################################################################
    def get(ref)
        if !@items[ref.to_sym]
            rbvmomi_dc = RbVmomi::VIM::Datacenter.new(@vi_client.vim, ref)
            @items[ref.to_sym] = Datacenter.new(rbvmomi_dc)
        end

        @items[ref.to_sym]
    end

    def get_vcenter_instance_uuid
        @vi_client.vim.serviceContent.about.instanceUuid
    end

    def get_vcenter_api_version
        @vi_client.vim.serviceContent.about.apiVersion
    end

    def get_unimported_hosts(hpool, vcenter_instance_name)
        host_objects = {}

        vcenter_uuid = get_vcenter_instance_uuid

        vcenter_version = get_vcenter_api_version

        fetch! if @items.empty? #Get datacenters

        @items.values.each do |dc|
            dc_name = dc.item.name
            host_objects[dc_name] = []

            host_folder = dc.host_folder
            host_folder.fetch_clusters!
            host_folder.items.values.each do |ccr|

                one_host = VCenterDriver::VIHelper.find_by_ref(OpenNebula::HostPool,
                                                               "TEMPLATE/VCENTER_CCR_REF",
                                                               ccr['_ref'],
                                                               vcenter_uuid,
                                                               hpool)

                next if one_host #If the host has been already imported

                cluster = VCenterDriver::ClusterComputeResource.new_from_ref(ccr['_ref'], @vi_client)
                rpools = cluster.get_resource_pool_list.select {|rp| !rp[:name].empty?}

                host_info = {}
                cluster_name = "[#{vcenter_instance_name}-#{dc_name}]_#{ccr['name']}"
                cluster_name = cluster_name.tr(" ", "_")
                cluster_name = cluster_name.tr("\u007F", "") # Remove \u007F character that comes from vcenter

                host_info[:cluster_name]     = cluster_name
                host_info[:cluster_ref]      = ccr['_ref']
                host_info[:vcenter_uuid]     = vcenter_uuid
                host_info[:vcenter_version]  = vcenter_version
                host_info[:rp_list]          = rpools

                host_objects[dc_name] << host_info
            end
        end

        return host_objects
    end

    def get_unimported_datastores(dpool, vcenter_instance_name, hpool)

        ds_objects = {}

        vcenter_uuid = get_vcenter_instance_uuid

        fetch! if @items.empty? #Get datacenters

        one_clusters = {}

        @items.values.each do |dc|
            dc_name = dc.item.name

            one_clusters[dc_name] = []

            host_folder = dc.host_folder
            host_folder.fetch_clusters!

            host_folder.items.values.each do |ccr|
                cluster = {}
                cluster[:ref]  = ccr['_ref']
                cluster[:name] = ccr['name']
                attribute = "TEMPLATE/VCENTER_CCR_REF"
                one_host = VCenterDriver::VIHelper.find_by_ref(OpenNebula::HostPool,
                                                               attribute,
                                                               ccr['_ref'],
                                                               vcenter_uuid,
                                                               hpool)

                if !!one_host
                    cluster[:host_id] = one_host['ID']
                    one_clusters[dc_name] << cluster
                end
            end

            next if one_clusters[dc_name].empty? #No clusters imported, continue
            ds_objects[dc_name] = []

            datastore_folder = dc.datastore_folder
            datastore_folder.fetch!

            datastore_folder.items.values.each do |ds|

                name, capacity, freeSpace = ds.item.collect("name","summary.capacity","summary.freeSpace")

                ds_name = "[#{vcenter_instance_name} - #{dc_name}] #{name}"
                ds_total_mb =  ((capacity.to_i / 1024) / 1024)
                ds_free_mb = ((freeSpace.to_i / 1024) / 1024)

                if ds.instance_of? VCenterDriver::Datastore
                    hosts_in_ds = ds['host']
                    clusters_in_ds = {}

                    hosts_in_ds.each do |host|
                        cluster_ref = host.key.parent._ref
                        if !clusters_in_ds[cluster_ref]
                            clusters_in_ds[cluster_ref] = host.key.parent.name
                        end
                    end

                    clusters_in_ds.each do |ccr_ref, ccr_name|
                        ds_hash = {}

                        ds_hash[:name] = "#{ds_name} - #{ccr_name.tr(" ", "_")}"
                        ds_hash[:total_mb] = ds_total_mb
                        ds_hash[:free_mb]  = ds_free_mb
                        ds_hash[:cluster]  = ccr_name
                        ds_hash[:ds]      = []

                        already_image_ds = VCenterDriver::Storage.exists_one_by_ref_ccr_and_type?(ds["_ref"], ccr_ref, vcenter_uuid, "IMAGE_DS", dpool)

                        if !already_image_ds
                            object = ds.to_one_template(one_clusters[dc_name], ds_hash[:name], ccr_ref, "IMAGE_DS", vcenter_uuid)
                            ds_hash[:ds] << object if !object.nil?
                        end

                        already_system_ds = VCenterDriver::Storage.exists_one_by_ref_ccr_and_type?(ds["_ref"], ccr_ref, vcenter_uuid, "SYSTEM_DS", dpool)

                        if !already_system_ds
                            object = ds.to_one_template(one_clusters[dc_name], ds_hash[:name], ccr_ref, "SYSTEM_DS", vcenter_uuid)
                            ds_hash[:ds] << object if !object.nil?
                        end

                        ds_objects[dc_name] << ds_hash if !ds_hash[:ds].empty?
                    end
                end

                if ds.instance_of? VCenterDriver::StoragePod
                    clusters_in_spod = {}
                    ds_in_spod = ds['children']

                    ds_in_spod.each do |sp_ds|
                        hosts_in_ds = sp_ds.host
                        hosts_in_ds.each do |host|
                            cluster_ref = host.key.parent._ref
                            if !clusters_in_spod[cluster_ref]
                                clusters_in_spod[cluster_ref] = host.key.parent.name
                            end
                        end
                    end

                    clusters_in_spod.each do |ccr_ref, ccr_name|
                        ds_hash = {}
                        ds_hash[:name] = "#{ds_name} - #{ccr_name.tr(" ", "_")}"
                        ds_hash[:total_mb] = ds_total_mb
                        ds_hash[:free_mb]  = ds_free_mb
                        ds_hash[:cluster]  = ccr_name
                        ds_hash[:ds]      = []

                        ds_hash[:ds] = []
                        already_system_ds = VCenterDriver::Storage.exists_one_by_ref_ccr_and_type?(ds["_ref"], ccr_ref, vcenter_uuid, "SYSTEM_DS", dpool)

                        if !already_system_ds
                            object = ds.to_one_template(one_clusters[dc_name], ds_hash[:name], ccr_ref, "SYSTEM_DS", vcenter_uuid)
                            ds_hash[:ds] << object if !object.nil?
                        end

                        ds_objects[dc_name] << ds_hash if !ds_hash[:ds].empty?
                    end
                end
            end
        end
        ds_objects
    end

    def get_unimported_templates(vi_client, tpool)
        template_objects = {}
        vcenter_uuid = get_vcenter_instance_uuid

        vcenter_instance_name = vi_client.vim.host

        fetch! if @items.empty? #Get datacenters

        @items.values.each do |dc|
            rp_cache = {}
            dc_name = dc.item.name
            template_objects[dc_name] = []


            view = vi_client.vim.serviceContent.viewManager.CreateContainerView({
                container: dc.item.vmFolder,
                type:      ['VirtualMachine'],
                recursive: true
            })

            pc = vi_client.vim.serviceContent.propertyCollector

            filterSpec = RbVmomi::VIM.PropertyFilterSpec(
            :objectSet => [
                :obj => view,
                :skip => true,
                :selectSet => [
                RbVmomi::VIM.TraversalSpec(
                    :name => 'traverseEntities',
                    :type => 'ContainerView',
                    :path => 'view',
                    :skip => false
                )
                ]
            ],
            :propSet => [
                { :type => 'VirtualMachine', :pathSet => ['config.template'] }
            ]
            )

            result = pc.RetrieveProperties(:specSet => [filterSpec])

            vms = {}
                result.each do |r|
                vms[r.obj._ref] = r.to_hash if r.obj.is_a?(RbVmomi::VIM::VirtualMachine)
            end
            templates = []
            vms.each do |ref,value|
                if value["config.template"]
                    templates << VCenterDriver::Template.new_from_ref(ref, vi_client)
                end
            end

            view.DestroyView # Destroy the view


            templates.each do |template|

                one_template = VCenterDriver::VIHelper.find_by_ref(OpenNebula::TemplatePool,
                                                                   "TEMPLATE/VCENTER_TEMPLATE_REF",
                                                                   template['_ref'],
                                                                   vcenter_uuid,
                                                                   tpool)

                next if one_template #If the template has been already imported

                one_template = VCenterDriver::Template.get_xml_template(template, vcenter_uuid, vi_client, vcenter_instance_name, dc_name, rp_cache)

                template_objects[dc_name] << one_template if !!one_template
            end
        end

        template_objects
    end

    def get_unimported_networks(npool,vcenter_instance_name)

        network_objects = {}
        vcenter_uuid = get_vcenter_instance_uuid

        pc = @vi_client.vim.serviceContent.propertyCollector

        #Get all port groups and distributed port groups in vcenter instance
        view = @vi_client.vim.serviceContent.viewManager.CreateContainerView({
                container: @vi_client.vim.rootFolder,
                type:      ['Network','DistributedVirtualPortgroup'],
                recursive: true
        })

        filterSpec = RbVmomi::VIM.PropertyFilterSpec(
            :objectSet => [
                :obj => view,
                :skip => true,
                :selectSet => [
                RbVmomi::VIM.TraversalSpec(
                    :name => 'traverseEntities',
                    :type => 'ContainerView',
                    :path => 'view',
                    :skip => false
                )
                ]
            ],
            :propSet => [
                { :type => 'Network', :pathSet => ['name'] },
                { :type => 'DistributedVirtualPortgroup', :pathSet => ['name'] }
            ]
        )

        result = pc.RetrieveProperties(:specSet => [filterSpec])

        networks = {}
            result.each do |r|
            networks[r.obj._ref] = r.to_hash if r.obj.is_a?(RbVmomi::VIM::DistributedVirtualPortgroup) || r.obj.is_a?(RbVmomi::VIM::Network)
            networks[r.obj._ref][:network_type] = r.obj.is_a?(RbVmomi::VIM::DistributedVirtualPortgroup) ? "Distributed Port Group" : "Port Group"
        end

        view.DestroyView # Destroy the view

        fetch! if @items.empty? #Get datacenters

        @items.values.each do |dc|

            dc_name = dc.item.name
            network_objects[dc_name] = []

            view = @vi_client.vim.serviceContent.viewManager.CreateContainerView({
                container: dc.item,
                type:      ['ClusterComputeResource'],
                recursive: true
            })

            filterSpec = RbVmomi::VIM.PropertyFilterSpec(
                :objectSet => [
                    :obj => view,
                    :skip => true,
                    :selectSet => [
                    RbVmomi::VIM.TraversalSpec(
                        :name => 'traverseEntities',
                        :type => 'ContainerView',
                        :path => 'view',
                        :skip => false
                    )
                    ]
                ],
                :propSet => [
                    { :type => 'ClusterComputeResource', :pathSet => ['name','network'] }
                ]
            )

            result = pc.RetrieveProperties(:specSet => [filterSpec])

            clusters = {}
                result.each do |r|
                clusters[r.obj._ref] = r.to_hash if r.obj.is_a?(RbVmomi::VIM::ClusterComputeResource)
            end

            view.DestroyView # Destroy the view

            clusters.each do |ref, info|

                network_obj = info['network']

                network_obj.each do |n|
                    network_ref  = n._ref
                    network_name = networks[network_ref]['name']
                    network_type = networks[network_ref][:network_type]

                    one_network = VCenterDriver::VIHelper.find_by_ref(OpenNebula::VirtualNetworkPool,
                                                                    "TEMPLATE/VCENTER_NET_REF",
                                                                    network_ref,
                                                                    vcenter_uuid,
                                                                    npool)
                    next if one_network #If the network has been already imported

                    one_vnet = VCenterDriver::Network.to_one_template(network_name,
                                                                        network_ref,
                                                                        network_type,
                                                                        ref,
                                                                        info['name'],
                                                                        vcenter_uuid,
                                                                        vcenter_instance_name,
                                                                        dc_name)
                    network_objects[dc_name] << one_vnet
                end

            end # network loop
        end #datacenters loop

        return network_objects

    end

end # class DatatacenterFolder

class Datacenter
    attr_accessor :item

    DPG_CREATE_TIMEOUT = 240

    def initialize(item, vi_client=nil)
        if !item.instance_of? RbVmomi::VIM::Datacenter
            raise "Expecting type 'RbVmomi::VIM::Datacenter'. " <<
                  "Got '#{item.class} instead."
        end

        @vi_client = vi_client
        @item = item
        @net_rollback = []
        @locking = true
    end

    def datastore_folder
        DatastoreFolder.new(@item.datastoreFolder)
    end

    def host_folder
        HostFolder.new(@item.hostFolder)
    end

    def vm_folder
        VirtualMachineFolder.new(@item.vmFolder)
    end

    def network_folder
        NetworkFolder.new(@item.networkFolder)
    end

    # Locking function. Similar to flock
    def lock
        hostlockname = @item['name'].downcase.tr(" ", "_")
        if @locking
           @locking_file = File.open("/tmp/vcenter-dc-#{hostlockname}-lock","w")
           @locking_file.flock(File::LOCK_EX)
        end
    end

    # Unlock driver execution mutex
    def unlock
        if @locking
            @locking_file.close
        end
    end

    ########################################################################
    # Check if distributed virtual switch exists in host
    ########################################################################
    def dvs_exists(switch_name, net_folder)

        return net_folder.items.values.select{ |dvs|
            dvs.instance_of?(VCenterDriver::DistributedVirtualSwitch) &&
            dvs['name'] == switch_name
        }.first rescue nil
    end

    ########################################################################
    # Is the distributed switch for the distributed pg different?
    ########################################################################
    def pg_changes_sw?(dpg, switch_name)
        return dpg['config.distributedVirtualSwitch.name'] != switch_name
    end

    ########################################################################
    # Create a distributed vcenter switch in a datacenter
    ########################################################################
    def create_dvs(switch_name, pnics, mtu=1500)
        # Prepare spec for DVS creation
        spec = RbVmomi::VIM::DVSCreateSpec.new
        spec.configSpec = RbVmomi::VIM::VMwareDVSConfigSpec.new
        spec.configSpec.name = switch_name

        # Specify number of uplinks port for dpg
        if pnics
            pnics = pnics.split(",")
            if !pnics.empty?
                spec.configSpec.uplinkPortPolicy = RbVmomi::VIM::DVSNameArrayUplinkPortPolicy.new
                spec.configSpec.uplinkPortPolicy.uplinkPortName = []
                (0..pnics.size-1).each { |index|
                    spec.configSpec.uplinkPortPolicy.uplinkPortName[index]="dvUplink#{index+1}"
                }
            end
        end

        #Set maximum MTU
        spec.configSpec.maxMtu = mtu

        # The DVS must be created in the networkFolder of the datacenter
        begin
            dvs_creation_task = @item.networkFolder.CreateDVS_Task(:spec => spec)
            dvs_creation_task.wait_for_completion

            # If task finished successfuly we rename the uplink portgroup
            dvs = nil
            if dvs_creation_task.info.state == 'success'
                dvs = dvs_creation_task.info.result
                dvs.config.uplinkPortgroup[0].Rename_Task(:newName => "#{switch_name}-uplink-pg").wait_for_completion
            else
                raise "The Distributed vSwitch #{switch_name} could not be created. "
            end
        rescue Exception => e
            raise e
        end

        @net_rollback << {:action => :delete_dvs, :dvs => dvs, :name => switch_name}

        return VCenterDriver::DistributedVirtualSwitch.new(dvs, @vi_client)
    end

    ########################################################################
    # Update a distributed vcenter switch
    ########################################################################
    def update_dvs(dvs, pnics, mtu)
        # Prepare spec for DVS creation
        spec = RbVmomi::VIM::VMwareDVSConfigSpec.new
        changed = false

        orig_spec = RbVmomi::VIM::VMwareDVSConfigSpec.new
        orig_spec.maxMtu = dvs['config.maxMtu']
        orig_spec.uplinkPortPolicy = RbVmomi::VIM::DVSNameArrayUplinkPortPolicy.new
        orig_spec.uplinkPortPolicy.uplinkPortName = []
        (0..dvs['config.uplinkPortgroup'].length-1).each { |index|
                orig_spec.uplinkPortPolicy.uplinkPortName[index]="dvUplink#{index+1}"
        }

        # Add more uplinks to default uplink port group according to number of pnics
        if pnics
            pnics = pnics.split(",")
            if !pnics.empty? && dvs['config.uplinkPortgroup'].length != pnics.size
                spec.uplinkPortPolicy = RbVmomi::VIM::DVSNameArrayUplinkPortPolicy.new
                spec.uplinkPortPolicy.uplinkPortName = []
                (dvs['config.uplinkPortgroup'].length..num_pnics-1).each { |index|
                    spec.uplinkPortPolicy.uplinkPortName[index]="dvUplink#{index+1}"
                }
                changed = true
            end
        end

        #Set maximum MTU
        if mtu != dvs['config.maxMtu']
            spec.maxMtu = mtu
            changed = true
        end

        # The DVS must be created in the networkFolder of the datacenter
        if changed
            spec.configVersion = dvs['config.configVersion']

            begin
                dvs.item.ReconfigureDvs_Task(:spec => spec).wait_for_completion
            rescue Exception => e
                raise "The Distributed switch #{dvs['name']} could not be updated. "\
                      "Reason: #{e.message}"
            end

            @net_rollback << {:action => :update_dvs, :dvs => dvs.item, :name => dvs['name'], :spec => orig_spec}
        end
    end

    ########################################################################
    # Remove a distributed vcenter switch in a datacenter
    ########################################################################
    def remove_dvs(dvs)
        begin
            dvs.item.Destroy_Task.wait_for_completion
        rescue
            #Ignore destroy task exception
        end
    end

    ########################################################################
    # Check if distributed port group exists in datacenter
    ########################################################################
    def dpg_exists(pg_name, net_folder)

        return net_folder.items.values.select{ |dpg|
            dpg.instance_of?(VCenterDriver::DistributedPortGroup) &&
            dpg['name'] == pg_name
        }.first rescue nil
    end

    ########################################################################
    # Create a distributed vcenter port group
    ########################################################################
    def create_dpg(dvs, pg_name, vlan_id, num_ports)
        spec = RbVmomi::VIM::DVPortgroupConfigSpec.new

        # OpenNebula use DVS static port binding with autoexpand
        if num_ports
            spec.autoExpand = true
            spec.numPorts = num_ports
        end

        # Distributed port group name
        spec.name = pg_name

        # Set VLAN information
        spec.defaultPortConfig = RbVmomi::VIM::VMwareDVSPortSetting.new
        spec.defaultPortConfig.vlan = RbVmomi::VIM::VmwareDistributedVirtualSwitchVlanIdSpec.new
        spec.defaultPortConfig.vlan.vlanId = vlan_id
        spec.defaultPortConfig.vlan.inherited = false

        # earlyBinding. A free DistributedVirtualPort will be selected and
        # assigned to a VirtualMachine when the virtual machine is reconfigured
        # to connect to the portgroup.
        spec.type = "earlyBinding"

        begin
            dvs.item.AddDVPortgroup_Task(spec: [spec]).wait_for_completion
        rescue Exception => e
            raise "The Distributed port group #{pg_name} could not be created. "\
                  "Reason: #{e.message}"
        end

        # wait until the network is ready and we have a reference
        portgroups = dvs['portgroup'].select{ |dpg|
            dpg.instance_of?(RbVmomi::VIM::DistributedVirtualPortgroup) &&
            dpg['name'] == pg_name
        }

        (0..DPG_CREATE_TIMEOUT).each do
            break if !portgroups.empty?
            portgroups = dvs['portgroup'].select{ |dpg|
                dpg.instance_of?(RbVmomi::VIM::DistributedVirtualPortgroup) &&
                dpg['name'] == pg_name
            }
            sleep 1
        end

        raise "Cannot get VCENTER_NET_REF for new distributed port group" if portgroups.empty?

        @net_rollback << {:action => :delete_dpg, :dpg => portgroups.first, :name => pg_name}

        return portgroups.first._ref
    end

    ########################################################################
    # Update a distributed vcenter port group
    ########################################################################
    def update_dpg(dpg, vlan_id, num_ports)
        spec = RbVmomi::VIM::DVPortgroupConfigSpec.new

        changed = false

        orig_spec = RbVmomi::VIM::DVPortgroupConfigSpec.new
        orig_spec.numPorts = dpg['config.numPorts']
        orig_spec.defaultPortConfig = RbVmomi::VIM::VMwareDVSPortSetting.new
        orig_spec.defaultPortConfig.vlan = RbVmomi::VIM::VmwareDistributedVirtualSwitchVlanIdSpec.new
        orig_spec.defaultPortConfig.vlan.vlanId = dpg['config.defaultPortConfig.vlan.vlanId']
        orig_spec.defaultPortConfig.vlan.inherited = false

        if num_ports && num_ports != orig_spec.numPorts
            spec.numPorts = num_ports
            changed = true
        end

        # earlyBinding. A free DistributedVirtualPort will be selected and
        # assigned to a VirtualMachine when the virtual machine is reconfigured
        # to connect to the portgroup.
        spec.type = "earlyBinding"

        if vlan_id != orig_spec.defaultPortConfig.vlan.vlanId
            spec.defaultPortConfig = RbVmomi::VIM::VMwareDVSPortSetting.new
            spec.defaultPortConfig.vlan = RbVmomi::VIM::VmwareDistributedVirtualSwitchVlanIdSpec.new
            spec.defaultPortConfig.vlan.vlanId = vlan_id
            spec.defaultPortConfig.vlan.inherited = false
            changed = true
        end

        if changed

            spec.configVersion = dpg['config.configVersion']

            begin
                dpg.item.ReconfigureDVPortgroup_Task(:spec => spec).wait_for_completion
            rescue Exception => e
                raise "The Distributed port group #{dpg['name']} could not be created. "\
                      "Reason: #{e.message}"
            end

            @net_rollback << {:action => :update_dpg, :dpg => dpg.item, :name => dpg['name'], :spec => orig_spec}
        end

    end

    ########################################################################
    # Remove distributed port group from datacenter
    ########################################################################
    def remove_dpg(dpg)
        begin
            dpg.item.Destroy_Task.wait_for_completion
        rescue RbVmomi::VIM::ResourceInUse => e
            STDERR.puts "The distributed portgroup #{dpg["name"]} is in use so it cannot be deleted"
            return nil
        rescue Exception => e
            raise "The Distributed portgroup #{dpg["name"]} could not be deleted. Reason: #{e.message} "
        end
    end

    ########################################################################
    # Perform vcenter network rollback operations
    ########################################################################
    def network_rollback
        @net_rollback.reverse_each do |nr|

            case nr[:action]
                when :update_dpg
                    begin
                        nr[:dpg].ReconfigureDVPortgroupConfigSpec_Task(:spec => nr[:spec])
                    rescue Exception => e
                        raise "A rollback operation for distributed port group #{nr[:name]} could not be performed. Reason: #{e.message}"
                    end
                when :update_dvs
                    begin
                        nr[:dvs].ReconfigureDvs_Task(:spec => nr[:spec])
                    rescue Exception => e
                        raise "A rollback operation for distributed standard switch #{nr[:name]} could not be performed. Reason: #{e.message}"
                    end
                when :delete_dvs
                    begin
                        nr[:dvs].Destroy_Task.wait_for_completion
                    rescue RbVmomi::VIM::ResourceInUse
                        return #Ignore if switch in use
                    rescue RbVmomi::VIM::NotFound
                        return #Ignore if switch not found
                    rescue Exception => e
                        raise "A rollback operation for standard switch #{nr[:name]} could not be performed. Reason: #{e.message}"
                    end
                when :delete_dpg
                    begin
                        nr[:dpg].Destroy_Task.wait_for_completion
                    rescue RbVmomi::VIM::ResourceInUse
                        return #Ignore if pg in use
                    rescue RbVmomi::VIM::NotFound
                        return #Ignore if pg not found
                    rescue Exception => e
                        raise "A rollback operation for standard port group #{nr[:name]} could not be performed. Reason: #{e.message}"
                    end
            end
        end
    end

    def self.new_from_ref(ref, vi_client)
        self.new(RbVmomi::VIM::Datacenter.new(vi_client.vim, ref), vi_client)
    end
end

end # module VCenterDriver
