# This file should contain all the record creation needed to seed the database with its default values.
# The data can then be loaded with the rake db:seed (or created alongside the db with db:setup).
#
# Examples:
#
#   cities = City.create([{ :name => 'Chicago' }, { :name => 'Copenhagen' }])
#   Mayor.create(:name => 'Daley', :city => cities.first)

# Libs
require 'facter'
require 'securerandom'

private_int = 'PRIV_INTERFACE'
public_int  = 'PUB_INTERFACE'

# Template texts - the trailing newline is important!
provision_text='install
<%= @mediapath %>
lang en_US.UTF-8
selinux --enforcing
keyboard us
skipx
network --bootproto <%= @static ? "static" : "dhcp" %> --hostname <%= @host %>
rootpw --iscrypted <%= root_pass %>
firewall --<%= @host.operatingsystem.major.to_i >= 6 ? "service=" : "" %>ssh
authconfig --useshadow --enablemd5
timezone UTC
<% if @host.operatingsystem.name == "Fedora" -%>
repo --name=fedora-everything --mirrorlist=https://mirrors.fedoraproject.org/metalink?repo=fedora-<%= @host.operatingsystem.major %>&arch=<%= @host.architecture %>
<% end -%>
<% if @host.operatingsystem.name == "Fedora" and @host.operatingsystem.major.to_i <= 16 -%>
# Bootloader exception for Fedora 16:
bootloader --append="nofb quiet splash=quiet <%=ks_console%>" <%= grub_pass %>
part biosboot --fstype=biosboot --size=1
<% else -%>
bootloader --location=mbr --append="nofb quiet splash=quiet" <%= grub_pass %>
<% end -%>
<% if @host.os.name == "RedHat" -%>
key --skip
<% end -%>

<% if @dynamic -%>
%include /tmp/diskpart.cfg
<% else -%>
<%= @host.diskLayout %>
<% end -%>
text
reboot

%packages
yum
dhclient
ntp
wget
@Core
<%= "%end\n" if @host.operatingsystem.name == "Fedora" %>

<% if @dynamic -%>
%pre
<%= @host.diskLayout %>
<% end -%>

%post --nochroot
exec < /dev/tty3 > /dev/tty3
#changing to VT 3 so that we can see whats going on....
/usr/bin/chvt 3
(
cp -va /etc/resolv.conf /mnt/sysimage/etc/resolv.conf
/usr/bin/chvt 1
) 2>&1 | tee /mnt/sysimage/root/install.postnochroot.log
<%= "%end\n" if @host.operatingsystem.name == "Fedora" %>

%post
logger "Starting anaconda <%= @host %> postinstall"
exec < /dev/tty3 > /dev/tty3
#changing to VT 3 so that we can see whats going on....
/usr/bin/chvt 3
(
#update local time
echo "updating system time"
/usr/sbin/ntpdate -sub <%= @host.params["ntp-server"] || "0.fedora.pool.ntp.org" %>
/usr/sbin/hwclock --systohc

# install epel if we can
<%= snippet "epel" %>

# update all the base packages from the updates repository
yum -t -y -e 0 update

# and add the puppet package
yum -t -y -e 0 install puppet

echo "Configuring puppet"
cat > /etc/puppet/puppet.conf << EOF
<%= snippets "puppet.conf" %>
EOF

# Setup puppet to run on system reboot
/sbin/chkconfig --level 345 puppet on

# Disable most things. Puppet will activate these if required.
echo "Disabling various system services"
<% %w{autofs gpm sendmail cups iptables ip6tables auditd arptables_jf xfs pcmcia isdn rawdevices hpoj bluetooth openibd avahi-daemon avahi-dnsconfd hidd hplip pcscd restorecond mcstrans rhnsd yum-updatesd}.each do |service| -%>
  /sbin/chkconfig --level 345 <%= service %> off 2>/dev/null
  <% end -%>

  /usr/bin/puppet agent --config /etc/puppet/puppet.conf -o --tags no_such_tag --server <%= @host.puppetmaster %>  --no-daemonize

  sync

# Inform the build system that we are done.
echo "Informing Foreman that we are built"
wget -q -O /dev/null --no-check-certificate <%= foreman_url %>
# Sleeping an hour for debug
) 2>&1 | tee /root/install.post.log
exit 0

<%= "%end\n" if @host.operatingsystem.name == "Fedora" -%>
'
pxe_text='default linux
label linux
kernel <%= @kernel %>
append initrd=<%= @initrd %> ks=<%= foreman_url("provision")%> ksdevice=bootif network kssendmac
'
ptable_text='zerombr
clearpart --all --initlabel
autopart
'

# Disable CA management as the proxy has issues using sudo with SCL
Setting[:manage_puppetca] = false

# Set correct hostname
Setting[:foreman_url] = Facter.fqdn

# Create an OS to assign things to. We'll come back later to finish it's config
os = Operatingsystem.where(:name => "CentOS", :major => "6", :minor => "4").first
os ||= Operatingsystem.create(:name => "CentOS", :major => "6", :minor => "4")
os.type = "Redhat"
os.save!

# Installation Media - comes as standard, just need to associate it
m=Medium.find_or_create_by_name("OpenStack RHEL mirror")
m.path="http://mirror.ox.ac.uk/sites/mirror.centos.org/$major.$minor/os/$arch"
m.os_family="Redhat"
m.operatingsystems << os
m.save!

# OS parameters for RHN(S) registration, see redhat_register snippet
{
  # "site" for local Satellite, "hosted" for RHN
  "spacewalk_type" => "site",
  "spacewalk_host" => "satellite.example.com",
  # Activation key must have OpenStack child channel
  "activation_key" => "1-example",
}.each do |k,v|
  p=OsParameter.find_or_create_by_name(k)
  p.value = v
  p.reference_id = os.id
  p.save!
end

# Add Proxy
# Figure out how to call this before the class import
# SmartProxy.new(:name => "OpenStack Smart Proxy", :url => "https://#{Facter.fqdn}:8443"

# Architecures
a=Architecture.find_or_create_by_name "x86_64"
a.operatingsystems << os
a.save!

# Domains
d=Domain.find_or_create_by_name Facter.domain
d.fullname="OpenStack: #{Facter.domain}"
d.dns = Feature.find_by_name("DNS").smart_proxies.first
d.save!

# Subnets - use Import Subnet code
s=Subnet.find_or_create_by_name "OpenStack"
s.network=Facter.send "network_#{private_int}"
s.mask=Facter.send "netmask_#{private_int}"
s.dhcp = Feature.find_by_name("DHCP").smart_proxies.first
s.dns = Feature.find_by_name("DNS").smart_proxies.first
s.tftp = Feature.find_by_name("TFTP").smart_proxies.first
s.domains=[d]
s.save!

# Templates
pt   = Ptable.find_or_initialize_by_name "OpenStack Disk Layout"
data = {
  :layout           => ptable_text,
  :os_family        => "Redhat"
}
pt.update_attributes(data)
pt.save!

pxe = ConfigTemplate.find_or_initialize_by_name "OpenStack PXE Template"
data = {
  :template         => pxe_text,
  :operatingsystems => ( pxe.operatingsystems << os ).uniq,
  :snippet          => false,
  :template_kind_id => TemplateKind.find_by_name("PXELinux").id
}
pxe.update_attributes(data)
pxe.save!

ks = ConfigTemplate.find_or_initialize_by_name "OpenStack Kickstart Template"
data = {
  :template         => provision_text,
  :operatingsystems => ( ks.operatingsystems << os ).uniq,
  :snippet          => false,
  :template_kind_id => TemplateKind.find_by_name("provision").id
}
ks.update_attributes(data)
ks.save!

# Finish updating the OS
os.ptables = [pt]
['provision','PXELinux'].each do |kind|
  kind_id = TemplateKind.find_by_name(kind).id
  if os.os_default_templates.where(:template_kind_id => kind_id).blank?
    os.os_default_templates.build(:template_kind_id => kind_id, :config_template_id => ks.id)
  end
end
os.save!

# Override all the puppet class params for quickstack
primary_int=`route|grep default|awk ' { print ( $(NF) ) }'`.chomp
primary_prefix=Facter.send("network_#{primary_int}").split('.')[0..2].join('.')
sec_int_hash=Facter.to_hash.reject { |k| k !~ /^ipaddress_/ }.reject { |k| k =~ /lo|#{primary_int}/ }.first
secondary_int=sec_int_hash[0].split('_').last
secondary_prefix=sec_int_hash[1].split('.')[0..2].join('.')

params = {
  "verbose"                    => "true",
  "admin_password"             => SecureRandom.hex,
  "cinder_db_password"         => SecureRandom.hex,
  "cinder_user_password"       => SecureRandom.hex,
  "glance_db_password"         => SecureRandom.hex,
  "glance_user_password"       => SecureRandom.hex,
  "horizon_secret_key"         => SecureRandom.hex,
  "keystone_admin_token"       => SecureRandom.hex,
  "keystone_db_password"       => SecureRandom.hex,
  "mysql_root_password"        => SecureRandom.hex,
  "nova_db_password"           => SecureRandom.hex,
  "nova_user_password"         => SecureRandom.hex,
  "private_interface"          => private_int,
  "public_interface"           => public_int,
  "fixed_network_range"        => 'PRIV_RANGE',
  "floating_network_range"     => 'PUB_RANGE',
  "pacemaker_priv_floating_ip" => 'PRIV_IP',
  "pacemaker_pub_floating_ip"  => 'PUB_IP',
  "admin_email"                => "admin@#{Facter.domain}"
}

['quickstack::compute','quickstack::controller'].each do |pc|
pclass = Puppetclass.find_by_name pc
  params.each do |k,v|
    p = pclass.class_params.find_by_key(k)
    unless p.nil?
      p.default_value = v
      p.override = true
      p.save
    end
  end
end

# Hostgroups
h_controller=Hostgroup.find_or_create_by_name "OpenStack Controller"
h_controller.environment = Environment.find_by_name('production')
h_controller.puppetclasses = [ Puppetclass.find_by_name('quickstack::controller') ]
h_controller.save!

h_compute=Hostgroup.find_or_create_by_name "OpenStack Nova Compute"
h_compute.environment = Environment.find_by_name('production')
h_compute.puppetclasses = [ Puppetclass.find_by_name('quickstack::compute') ]
h_compute.save!

['OpenStack Controller','OpenStack Nova Compute'].each do |name|
  h=Hostgroup.find_by_name name
  h.puppet_proxy    = Feature.find_by_name("Puppet").smart_proxies.first
  h.puppet_ca_proxy = Feature.find_by_name("Puppet CA").smart_proxies.first
  h.os = os
  h.architecture = a
  h.medium = m
  h.ptable = pt
  h.subnet = s
  h.domain = d
  h.save!
end
