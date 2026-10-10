# -*- mode: ruby -*-
# Three bare servers, each with 5 small data disks for Garage S3. Nothing is provisioned here:
# Ansible (ansible/site.yml) sets them up. Both libvirt networks are isolated (no NAT), so the VMs have
# no internet access; the host reaches them on 192.168.56.0/24.
NODES = {
  "lgtm1" => "192.168.56.11",
  "lgtm2" => "192.168.56.12",
  "lgtm3" => "192.168.56.13",
}

Vagrant.configure("2") do |config|
  config.vm.box = "cloud-image/ubuntu-24.04"
  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.provider :libvirt do |lv|
    lv.memory = 7168
    lv.cpus = 4
    lv.cpu_mode = "host-passthrough"
    lv.machine_virtual_size = 40 # GB root disk, grown by cloud-init
    5.times { lv.storage :file, size: "100M", bus: "virtio" } # /dev/vdb .. /dev/vdf
    # Vagrant's own SSH/DHCP network, isolated instead of NAT.
    lv.management_network_name = "lgtm-mgmt"
    lv.management_network_address = "192.168.57.0/24"
    lv.management_network_mode = "none"
  end

  NODES.each do |name, ip|
    config.vm.define name do |node|
      node.vm.hostname = name
      node.vm.network :private_network, ip: ip,
        libvirt__network_name: "lgtm-net", libvirt__forward_mode: "none", libvirt__dhcp_enabled: false
    end
  end
end
