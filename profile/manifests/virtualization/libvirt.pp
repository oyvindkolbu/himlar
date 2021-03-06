#
# class profile::virtualization::libvirt
#
class profile::virtualization::libvirt(
  $networks        = {},
  $pools           = {},
  $manage_firewall = false,
  $firewall_extras = {
    'tcp'      => {},
    'tls'      => {},
    'graphics' => {},
  },
) {
  include ::libvirt

  validate_hash($networks)
  validate_hash($pools)

  create_resources('::libvirt::network', $networks)
  create_resources(libvirt_pool, $pools)

  if $manage_firewall {
    profile::firewall::rule { '180 libvirt-tcp accept tcp':
      port   => 16509,
      extras => $firewall_extras['tcp']
    }

    profile::firewall::rule { '181 libvirt-tls accept tcp':
      port   => 16514,
      extras => $firewall_extras['tls']
    }

    profile::firewall::rule { '182 libvirt-graphics console accept tcp':
      port   => 5900,
      extras => $firewall_extras['graphics']
    }
  }
}
