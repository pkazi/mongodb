node.override['mongodb']['package_name'] = 'percona-server-mongodb'
# node.override['mongodb']['dbconfig_file']['mongos'] = '/etc/mongod.conf'
package_repo_url = case node['platform']
                   when 'redhat', 'centos'
                     'https://repo.percona.com/psmdb-40/yum/release/$releasever/RPMS/$basearch'
                   else
                     raise 'This cookbook supprots only redhat/centos platform for percona server for mongodb package'
                   end
gpgkey_url = 'https://www.percona.com/downloads/RPM-GPG-KEY-percona'

yum_repository 'psmdb-40-release' do
  description 'psmdb-40-release RPM Repository'
  baseurl package_repo_url
  gpgkey gpgkey_url
  gpgcheck true
  sslverify true
  enabled true
end
