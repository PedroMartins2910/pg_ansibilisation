# Lab: 3 x Rocky Linux 9 on a private network (VIP 192.168.56.10)
#   vagrant up
#   ansible-playbook -i inventories/lab/hosts.yml playbooks/lab_prepare.yml playbooks/site.yml
NODES = { "lab-pg1" => "192.168.56.11", "lab-pg2" => "192.168.56.12", "lab-wit" => "192.168.56.13" }

Vagrant.configure("2") do |config|
  config.vm.box = "generic/rocky9"
  config.vm.synced_folder ".", "/vagrant", disabled: true
  NODES.each do |name, ip|
    config.vm.define name do |node|
      node.vm.hostname = name
      node.vm.network "private_network", ip: ip
      node.vm.provider "virtualbox" do |vb|
        vb.memory = 1024
        vb.cpus = 2
      end
    end
  end
end
