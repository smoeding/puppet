test_name "autosign command and csr attributes behavior (#7243,#7244)" do
  skip_test "Test requires at least one non-master agent" if hosts.length == 1

  tag 'audit:high',        # cert/ca core behavior
      'audit:integration',
      'server'             # Ruby implementation is deprecated

  def assert_key_generated(name, stdout)
    assert_match(/Creating a new RSA SSL key for #{name}/, stdout, "Expected agent to create a new SSL key for autosigning")
  end

  testdirs = {}
  test_certnames = []

  step "Generate tmp dirs on all hosts" do
    hosts.each do |host|
      testdirs[host] = host.tmpdir('autosign_command')
      on(host, "chmod 755 #{testdirs[host]}")
    end
  end

  hostname = master.execute('facter hostname')
  fqdn = master.execute('facter fqdn')

  teardown do
    step "clear test certs"
    master_opts = {
      'main' => { 'server' => fqdn },
      'master' => { 'dns_alt_names' => "puppet,#{hostname},#{fqdn}" }
    }
    with_puppet_running_on(master, master_opts) do
      on(master,
         "puppetserver ca clean --certname #{test_certnames.join(',')}",
         :acceptable_exit_codes => [0,24])
    end
  end

  step "Step 1: ensure autosign command can approve CSRs" do

    # Our script needs to consume stdin (SERVER-1116)
    # We should revert back to /bin/true once resolved
    autosign_true_script = <<-EOF
!#/bin/bash
while read line
do
    : # noop command
done
exit 0
EOF

    autosign_true_script_path = "#{testdirs[master]}/mytrue"
    create_remote_file(master, autosign_true_script_path, autosign_true_script)
    on(master, "chmod 777 #{autosign_true_script_path}")

    master_opts = {
      'master' => {
        'autosign' => autosign_true_script_path,
        'dns_alt_names' => "puppet,#{hostname},#{fqdn}"
      }
    }
    with_puppet_running_on(master, master_opts) do
      agents.each do |agent|
        next if agent == master

        test_certnames << (certname = "#{agent}-autosign")
        on(agent, puppet("agent --test",
                  "--waitforcert 0",
                  "--ssldir", "'#{testdirs[agent]}/ssldir-autosign'",
                  "--certname #{certname}"), :acceptable_exit_codes => [0,2]) do |result|
          unless agent['locale'] == 'ja'
            assert_key_generated(agent, result.stdout)
            assert_match(/Downloaded certificate for #{agent}/, result.stdout, "Expected certificate to be autosigned")
          end
        end
      end
    end
  end

  step "Step 2: ensure autosign command can reject CSRs" do

    # Our script needs to consume stdin (SERVER-1116)
    # We should revert back to /bin/false once resolved
    autosign_false_script = <<-EOF
!#/bin/bash
while read line
do
    : # noop command
done
exit 1
EOF

    autosign_false_script_path = "#{testdirs[master]}/myfalse"
    create_remote_file(master, autosign_false_script_path, autosign_false_script)
    on(master, "chmod 777 #{autosign_false_script_path}")

    master_opts = {
      'master' => {
        'autosign' => autosign_false_script_path,
        'dns_alt_names' => "puppet,#{hostname},#{fqdn}"
      }
    }
    with_puppet_running_on(master, master_opts) do
      agents.each do |agent|
        next if agent == master

        test_certnames << (certname = "#{agent}-reject")
        on(agent, puppet("agent --test",
                        "--waitforcert 0",
                        "--ssldir", "'#{testdirs[agent]}/ssldir-reject'",
                        "--certname #{certname}"), :acceptable_exit_codes => [1]) do |result|
          unless agent['locale'] == 'ja'
            assert_key_generated(agent, result.stdout)
            assert_match(/Certificate for #{agent}-reject has not been signed yet/, result.stdout, "Expected certificate to not be autosigned")
          end
        end
      end
    end
  end

  autosign_inspect_csr_path = "#{testdirs[master]}/autosign_inspect_csr.rb"
  step "Step 3: setup an autosign command that inspects CSR attributes" do
    autosign_inspect_csr = <<-END
#!/opt/puppetlabs/puppet/bin/ruby
require 'openssl'

def unwrap_attr(attr)
  set = attr.value
  str = set.value.first
  str.value
end

csr_text = STDIN.read
csr = OpenSSL::X509::Request.new(csr_text)
passphrase = csr.attributes.find { |a| a.oid == '1.3.6.1.4.1.34380.2.1' }
# And here we jump hoops to unwrap ASN1's Attr Set Str
if unwrap_attr(passphrase) == 'my passphrase'
  exit 0
end
exit 1
    END
    create_remote_file(master, autosign_inspect_csr_path, autosign_inspect_csr)
    on master, "chmod 777 #{testdirs[master]}"
    on master, "chmod 777 #{autosign_inspect_csr_path}"
  end

  agent_csr_attributes = {}
  step "Step 4: create attributes for inclusion on csr on agents" do
    csr_attributes = <<-END
custom_attributes:
  1.3.6.1.4.1.34380.2.0: hostname.domain.com
  1.3.6.1.4.1.34380.2.1: my passphrase
  1.3.6.1.4.1.34380.2.2: # system IPs in hex
    - 0xC0A80001 # 192.168.0.1
    - 0xC0A80101 # 192.168.1.1
    END

    agents.each do |agent|
      agent_csr_attributes[agent] = "#{testdirs[agent]}/csr_attributes.yaml"
      create_remote_file(agent, agent_csr_attributes[agent], csr_attributes)
    end
  end

  step "Step 5: successfully obtain a cert" do
    master_opts = {
      'master' => {
        'autosign' => autosign_inspect_csr_path,
        'dns_alt_names' => "puppet,#{hostname},#{fqdn}"
      },
    }
    with_puppet_running_on(master, master_opts) do
      agents.each do |agent|
        next if agent == master

        step "attempting to obtain cert for #{agent}"
        test_certnames << (certname = "#{agent}-attrs")
        on(agent, puppet("agent --test",
                         "--waitforcert 0",
                         "--ssldir", "'#{testdirs[agent]}/ssldir-attrs'",
                         "--csr_attributes '#{agent_csr_attributes[agent]}'",
                         "--certname #{certname}"), :acceptable_exit_codes => [0,2]) do |result|
          assert_key_generated(agent, result.stdout) unless agent['locale'] == 'ja'
          assert_match(/Downloaded certificate for #{agent}/, result.stdout, "Expected certificate to be autosigned")
        end
      end
    end
  end
end
