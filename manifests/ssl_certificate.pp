#
# == Define: vault::ssl_certificate
#
# Create an SSL certificate using Vault's PKI secret backend, and configure
# automatic key rotation and certificate renewal.
#
# === Parameters
#
# [*host*]
#   String.  The value of this parameter is used as the common name in the
#   SSL certificate.
#   Default: undef
#
# [*domain*]
#   String.  The domain under which this certificate is being issued.  This
#   should match the role for Vault's PKI secret backend.
#   Default:  based on $host (everything after the first ".")
#
# [*aliases*]
#   Array.  A list of hostnames and IP addresses for use as subject
#   alternate names in the SSL certificate.
#   Default: []
#
# [*directory*]
#   String.  A fully qualified directory in which the certificate and key
#   file will be placed.  Required if either or both of the cert_pem or
#   key_pem parameter are not fully qualified filenames.
#   Default: undef
#
# [*cert_pem*]
#   String.  The certificate filename.  If not fully qualified, the file
#   will be placed in $directory.
#   Default: "${host}.cert.pem"
#
# [*key_pem*]
#   String.  The key filename.  If not fully qualified, the file will be
#   placed in $directory.
#   Default: "${host}.key.pem"
#
# [*post_rotate*]
#   String.  A script to be run in order to start using the updated key and
#   certificate.  Must be fully qualified.
#   Default: undef
#
# [*vault*]
#   String.  Base URL for Vault instance to connect to.
#   Default: https://127.0.0.1:8200
#
# [*lease_duration*]
#
# [*rotate_frequency*]
#
# === Example usage
#
#  file { '/etc/logstashforwarder/ssl':
#    ensure => 'directory',
#    owner  => 'root',
#    group  => 'root',
#    mode   => '0700',
#  }
#
#  vault::ssl_certificate { 'logstashforwarder':
#    host        => $::fqdn,
#    aliases     => [
#      '1.2.3.4',
#      'host.domain',
#      '5.6.7.8',
#    ],
#    directory   => '/etc/logstashforwarder/ssl',
#    post_rotate => '/usr/sbin/service logstashforwarder restart',
#  }
#
define vault::ssl_certificate(
  $host,
  $domain           = undef,
  $aliases          = [],
  $directory        = undef,
  $cert_pem         = "${host}.cert.pem",
  $key_pem          = "${host}.key.pem",
  $post_rotate      = undef,
  $vault            = undef,
  $lease_duration   = undef,
  $rotate_frequency = undef,
) {

  if ! defined(Class['vault']) {
    include vault
  }

  $_vault = $vault ? {
    undef   =>"${::vault::advertise_scheme}://${::vault::advertise_addr}:${::vault::advertise_port}",
    default => $vault,
  }

  $_lease_duration = $lease_duration ? {
    undef   => $::vault::lease_duration,
    default => $lease_duration,
  }

  $_rotate_frequency = $rotate_frequency ? {
    undef   => $::vault::rotate_frequency,
    default => $rotate_frequency,
  }

  # data validation
  validate_string($host)
  if $domain { validate_string($domain) }
  validate_array($aliases)
  if $directory { validate_absolute_path($directory) }
  elsif ! is_absolute_path($cert_pem) { validate_absolute_path($directory) }
  elsif ! is_absolute_path($key_pem) { validate_absolute_path($directory) }
  if $post_rotate { validate_string($post_rotate) }
  validate_string($_vault)

  # data mutation
  $sanitised_directory = regsubst($directory, '/$', '')  # remove trailing slash if present

  if is_absolute_path($cert_pem) {
    $cert_pem_full_path = $cert_pem
  } else {
    $cert_pem_full_path = "${sanitised_directory}/${cert_pem}"
  }

  if is_absolute_path($key_pem) {
    $key_pem_full_path = $key_pem
  } else {
    $key_pem_full_path = "${sanitised_directory}/${key_pem}"
  }

  $alt_names_array = $aliases.filter |$x| { ! is_ip_address($x) }
  $ip_sans_array   = $aliases.filter |$x| { is_ip_address($x) }

  if size($alt_names_array) > 0 {
    $alt_names = join(['--alt_names ', '"', join($alt_names_array, ', '), '"'], '')
  } else {
    $alt_names = ''
  }

  if size($ip_sans_array) > 0 {
    $ip_sans = join(['--ip_sans ', '"', join($ip_sans_array, ', '), '"'], '')
  } else {
    $ip_sans = ''
  }

  if $domain {
    $_domain = $domain
  } else {
    # generate $_domain based on $host
    $_domain = regsubst($host, '^[^\.]+\.', '')
  }


  # resource instantiation
  Exec <| title == 'vault-bootstrap' |> ->
  exec { "Deploy SSL certificate for ${title}":
    command     => "/usr/local/bin/deploy-ssl-certificate --domain ${_domain} --common_name ${host} ${alt_names} ${ip_sans} --lease ${_lease_duration} --certfile ${cert_pem_full_path} --keyfile ${key_pem_full_path}",
    unless      => "/usr/bin/test -f ${cert_pem_full_path} && /usr/bin/test -f ${key_pem_full_path}",
    environment => "VAULT_ADDR=${_vault}",
    tries       => 7,   # wait up to 60 seconds - designed to work with a DNS address advertised by Consul using a max 60s service check
    try_sleep   => 10,
    require     => File['/usr/local/bin/deploy-ssl-certificate'],
  } ->
  cron { "Rotate SSL certificate for ${title}":
    command => "env VAULT_ADDR=${_vault} /usr/local/bin/deploy-ssl-certificate --domain ${_domain} --common_name ${host} ${alt_names} ${ip_sans} --lease ${_lease_duration} --certfile ${cert_pem_full_path} --keyfile ${key_pem_full_path}",
    special => $_rotate_frequency,
    require => File['/usr/local/bin/deploy-ssl-certificate'],
  }

}
