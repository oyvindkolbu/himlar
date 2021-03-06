#!/bin/bash

# Be conservative
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

#
# Collect data
#
foreman_fqdn=$(hostname -f)
foreman_domain=${foreman_fqdn#*.}
foreman_location=${foreman_fqdn%%-*}
mgmt_interface=eth0
#mgmt_interface=$(hiera foreman_proxy::dhcp_interface role=foreman location=$foreman_location)
mgmt_network=$(facter network_${mgmt_interface})
mgmt_netmask=$(facter netmask_${mgmt_interface})

#
# Location specific configs
#
vagrant_config()
{
  #
  # Use the internal DNS server on vagrant, switch to it using Puppet
  #
  puppet apply -e "
  augeas { 'peerdns no':
    context => '/files/etc/sysconfig/network-scripts/ifcfg-eth0',
    changes => [ 'set PEERDNS no' ],
  }
  augeas { 'switch nameserver':
    context => '/files/etc/resolv.conf',
    changes => [ 'set nameserver 10.0.3.5' ],
  }
  "
}

bgo_config()
{
  return;
}
osl_config()
{
  return;
}
trd_config()
{
  return;
}
dev01_config()
{
  return;
}

#
# Common configuration
#
common_config()
{
  #
  # Network configuration objects
  #

  # Create and update domain
  hammer domain create --name $foreman_domain || true
  hammer domain update --name $foreman_domain --dns-id ''
  foreman_domain_id=$(hammer --csv domain info --name $foreman_domain | tail -n1 | cut -d, -f1)

  # Find smart proxy ID to use for tftp
  foreman_proxy_id=$(hammer --csv proxy info --name $foreman_fqdn | tail -n1 | cut -d, -f1)

  # Create and update subnet
  hammer subnet create --name mgmt \
    --network       $mgmt_network \
    --mask          $mgmt_netmask || true
  hammer subnet update --name mgmt \
    --network       $mgmt_network \
    --mask          $mgmt_netmask \
    --ipam          None \
    --domain-ids    $foreman_domain_id \
    --tftp-id       $foreman_proxy_id \
    --dns-primary   '' \
    --dns-secondary '' \
    --gateway       ''
#    --dns-id        '' \
#    --dhcp-id       ''
  foreman_subnet_id=$(hammer --csv subnet info --name mgmt | tail -n1 | cut -d, -f1)

  #
  # Provisioning and discovery setup
  #

  # Enable puppetlabs repo
  hammer global-parameter set --name enable-puppetlabs-repo --value true
  # Enable clokcsync in Kickstart
  hammer global-parameter set --name time-zone --value 'Europe/Oslo'
  hammer global-parameter set --name ntp-server --value 'no.pool.ntp.org'

  # Create ftp.uninett.no medium
  hammer medium create --name 'CentOS ftp.uninett.no' \
    --os-family Redhat \
    --path 'http://ftp.uninett.no/centos/$version/os/$arch' || true
  # Save CentOS mirror ids
  medium_id_1=$(hammer --csv medium info --name 'CentOS mirror' | tail -n1 | cut -d, -f1)
  medium_id_2=$(hammer --csv medium info --name 'CentOS ftp.uninett.no' | tail -n1 | cut -d, -f1)

  # Sync our custom provision templates
  foreman-rake templates:sync \
    repo="https://github.com/norcams/community-templates.git" branch="norcams" associate="always"
  # Save template ids
  norcams_provision_id=$(hammer --csv template list --per-page 1000 | grep 'norcams Kickstart default' | cut -d, -f1)
  norcams_pxelinux_id=$(hammer --csv template list --per-page 1000 | grep 'norcams PXELinux default' | cut -d, -f1)
  norcams_ptable_id=$(hammer --csv partition-table list --per-page 1000 | grep 'norcams ptable default' | cut -d, -f1)

  # Associate partition template with Redhat family of OSes
  hammer partition-table update --id $norcams_ptable_id --os-family Redhat

  # Create and update OS (we assume OS id is 1 for now)
  hammer os create --name CentOS --major 7 || true
  hammer os update --id 1 --name CentOS --major 7 \
    --description "CentOS 7" \
    --family Redhat \
    --architecture-ids 1 \
    --medium-ids ${medium_id_2},${medium_id_1} \
    --partition-table-ids $norcams_ptable_id
  # Set default Kickstart and PXELinux templates and associate with os
  hammer template update --id $norcams_provision_id --operatingsystem-ids 1
  hammer template update --id $norcams_pxelinux_id --operatingsystem-ids 1
  hammer os set-default-template --id 1 --config-template-id $norcams_provision_id
  hammer os set-default-template --id 1 --config-template-id $norcams_pxelinux_id

  # Create Puppet environment
  hammer environment create --name production || true

  # Create a base hostgroup
  hammer hostgroup create --name base || true
  hammer hostgroup update --name base \
    --architecture x86_64 \
    --domain-id $foreman_domain_id \
    --operatingsystem-id 1 \
    --medium-id $medium_id_2 \
    --partition-table-id $norcams_ptable_id \
    --subnet-id $foreman_subnet_id \
    --puppet-proxy-id $foreman_proxy_id \
    --puppet-ca-proxy-id $foreman_proxy_id \
    --environment production

  # Create storage hostgroup to set special paramters
  hammer hostgroup create --name storage --parent base || true
  hammer hostgroup set-parameter --hostgroup storage \
     --name installdevice \
     --value sdm

  #
  # Foreman global settings
  #
  # Thee last block below render the PXElinux default template with safe mode
  # rendering 'false'
  # - this is required for the discovery image to get the foreman_url setting
  # passed through to the kernel from the template
  #
  rootpw='Himlarchangeme'
  rootpw_md5=$(openssl passwd -1 $rootpw)
  echo '
    Setting["root_pass"]                    = "'$rootpw_md5'"
    Setting["entries_per_page"]             = 100
    Setting["foreman_url"]                  = "https://'$foreman_fqdn'"
    Setting["unattended_url"]               = "http://'$foreman_fqdn'"
    Setting["trusted_puppetmaster_hosts"]   = [ "'$foreman_fqdn'" ]
    Setting["discovery_fact_column"]        = "ipmi_ipaddress"
    Setting["update_ip_from_built_request"] = true
    Setting["use_shortname_for_vms"]        = true
    Setting["idle_timeout"]                 = 180

    Setting["safemode_render"] = false
    include Foreman::Renderer
    ConfigTemplate.build_pxe_default(self)
    Setting["safemode_render"] = true

  ' | foreman-rake console
}

#
# main
#
case $foreman_fqdn in
  vagrant-foreman-*)
    vagrant_config
    ;;
  bgo-foreman-*)
    bgo_config
    ;;
  osl-foreman-*)
    osl_config
    ;;
  trd-foreman-*)
    trd_config
    ;;
  dev01-foreman-*)
    dev01_config
    ;;
esac
common_config

