# -*- mode: ruby -*-
# vi: set ft=ruby :

VAGRANTFILE_API_VERSION = '2'

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
  config.vm.box = 'norcams/centos7'

  config.vm.synced_folder '.', '/vagrant', disabled: true
  config.vm.synced_folder '.', '/opt/himlar', type: 'rsync',
    rsync__exclude: [ '.git/', '.vagrant/' ]

  config.vm.provision :shell, :path => 'provision/bootstrap.sh'
  config.vm.provision :shell, :path => 'provision/puppetrun.sh', args: ENV['HIMLAR_CERTNAME']

  if Vagrant.has_plugin?('vagrant-cachier')
    config.cache.scope = :machine
  end

  config.vm.provider :virtualbox do |vbox|
    vbox.customize ['modifyvm', :id, '--ioapic', 'on']
    vbox.customize ['modifyvm', :id, '--cpus', 2]
    vbox.customize ['modifyvm', :id, '--memory', 1024]
  end

end

