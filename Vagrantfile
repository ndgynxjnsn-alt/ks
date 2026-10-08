# -*- mode: ruby -*-
# Three RKE2 servers (control plane + workloads), each with 5 small data disks for Garage S3.
require "securerandom"

# Servers must join etcd one after another.
ENV["VAGRANT_NO_PARALLEL"] = "yes"

VIP   = "192.168.56.10"
NODES = {
  "lgtm1" => "192.168.56.11",
  "lgtm2" => "192.168.56.12",
  "lgtm3" => "192.168.56.13",
}
RKE2_VERSION   = "v1.37.1+rke2r1"
KUBEVIP_VERSION = "v1.2.4"
GARAGE_VERSION = "v2.4.1"

# Cluster secrets are generated once on the host and synced to every VM (.secrets/ is gitignored).
SECRETS_FILE = File.join(__dir__, ".secrets", "cluster.env")
unless File.exist?(SECRETS_FILE)
  Dir.mkdir(File.dirname(SECRETS_FILE)) unless Dir.exist?(File.dirname(SECRETS_FILE))
  File.write(SECRETS_FILE, <<~ENV)
    RKE2_TOKEN=#{SecureRandom.hex(32)}
    GARAGE_RPC_SECRET=#{SecureRandom.hex(32)}
    GARAGE_ADMIN_TOKEN=#{SecureRandom.hex(32)}
    S3_ACCESS_KEY_ID=GK#{SecureRandom.hex(12)}
    S3_SECRET_ACCESS_KEY=#{SecureRandom.hex(32)}
  ENV
end

Vagrant.configure("2") do |config|
  config.vm.box = "cloud-image/ubuntu-24.04"
  config.vm.synced_folder ".", "/vagrant", type: "rsync",
    rsync__exclude: [".git/", ".vagrant/", ".bin/", "apps/", "*.tar"]

  config.vm.provider :libvirt do |lv|
    lv.memory = 7168
    lv.cpus = 4
    lv.cpu_mode = "host-passthrough"
    lv.machine_virtual_size = 40 # GB root disk, grown by cloud-init
    5.times { lv.storage :file, size: "100M", bus: "virtio" } # /dev/vdb .. /dev/vdf
  end

  NODES.each_with_index do |(name, ip), i|
    config.vm.define name do |node|
      node.vm.hostname = name
      node.vm.network :private_network, ip: ip
      node.vm.provision "shell", path: "provision/node.sh",
        env: {
          "NODE_IP" => ip, "VIP" => VIP, "FIRST_NODE" => (i == 0).to_s, "LAST_NODE" => (i == NODES.size - 1).to_s,
          "ALL_NODE_IPS" => NODES.values.join(" "),
          "RKE2_VERSION" => RKE2_VERSION, "KUBEVIP_VERSION" => KUBEVIP_VERSION, "GARAGE_VERSION" => GARAGE_VERSION,
        }
    end
  end
end
