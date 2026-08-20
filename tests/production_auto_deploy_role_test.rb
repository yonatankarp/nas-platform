#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "digest"
require "json"
require "open3"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
ROLE_TASKS = File.join(ROOT, "roles/production_auto_deploy/tasks/main.yml")
ROLE_DEFAULTS = File.join(ROOT, "roles/production_auto_deploy/defaults/main.yml")
ROLE_ARGUMENTS = File.join(ROOT, "roles/production_auto_deploy/meta/argument_specs.yml")
INSTALL_PLAY = File.join(ROOT, "install-production-auto-deploy.yml")
LAUNCHER_SOURCE = File.join(ROOT, "scripts/nas-platform-deploy")
POLLER_SOURCE = File.join(ROOT, "scripts/production_auto_deploy.py")
REPOSITORY_URL = "https://github.com/yonatankarp/nas-platform.git"
NAS_ADDRESS = "192.168.0.139"
TOKEN = "tk_#{'r' * 29}"
ROTATED_TOKEN = "tk_#{'s' * 29}"
LOCK_TEST_SHA = "f" * 40
# Real role scenarios normally finish in seconds; three minutes leaves ample room
# for a loaded runner without letting one Ansible process consume the CI job.
ROLE_COMMAND_TIMEOUT_SECONDS = 180
ROLE_COMMAND_TERM_GRACE_SECONDS = 1
ROLE_COMMAND_KILL_GRACE_SECONDS = 2
# Recent complete runs take 17-19 minutes, so this retains load tolerance while
# keeping the exact standalone suite bounded below the surrounding CI timeout.
ROLE_SUITE_BUDGET_SECONDS = 30 * 60
ROLE_COMMAND_TIMEOUT_DIAGNOSTIC = "production auto-deploy role test: Ansible invocation timed out\n"
POWER_BOUNDARY_TIMEOUT_DIAGNOSTIC = "production auto-deploy role test: power-boundary marker timed out\n"
POLL_CHILD_TIMEOUT_DIAGNOSTIC = "production auto-deploy role test: poll child timed out\n"
ROLE_SUITE_TIMEOUT_DIAGNOSTIC = "production auto-deploy role test: suite exceeded its wall-clock budget"

workflow = File.read(File.join(ROOT, ".github/workflows/ci.yml"))
integration = File.read(File.join(ROOT, "tests/integration.sh"))
controller_requirements = File.read(File.join(ROOT, "controller-requirements.txt"))
ci_pins = workflow.scan(
  /pip" install 'ansible-core==([0-9.]+)' 'ansible-lint==([0-9.]+)'/
)
integration_pins = integration.scan(/^ansible_core_version=([0-9.]+)$/).flatten
abort "CI must contain one exact Ansible controller pin pair" unless ci_pins.length == 1
expected_core, expected_lint = ci_pins.fetch(0)
abort "integration ansible-core pin must match CI" unless integration_pins == [expected_core]
abort "controller requirements must match current CI pins" unless
  controller_requirements ==
  "ansible-core==#{expected_core}\nansible-lint==#{expected_lint}\n"

def command_path(name)
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
    path = File.join(directory, name)
    return path if File.executable?(path)
  end
  nil
end

ansible = command_path("ansible-playbook")
abort "production auto-deploy role test requires ansible-playbook" unless ansible
version, status = Open3.capture2(ansible, "--version")
abort "production auto-deploy role test requires ansible-core #{expected_core}" unless
  status.success? && version.start_with?("ansible-playbook [core #{expected_core}]")

interpreter = File.realpath(File.open(ansible, &:readline).delete_prefix("#!").strip)
abort "production auto-deploy role test requires Ansible Python 3.12+" unless
  File.executable?(interpreter) &&
  system(interpreter, "-c", "import sys; raise SystemExit(sys.version_info < (3, 12))")

class ManagedChild
  def initialize(environment, *args, chdir: nil, process_scope: nil)
    options = { pgroup: true }
    options[:chdir] = chdir if chdir
    @stdin, @stdout, @stderr, @waiter = Open3.popen3(environment, *args, **options)
    @process_scope = process_scope
    @stdout_reader = drain(@stdout)
    @stderr_reader = drain(@stderr)
  end

  def close_stdin
    @stdin.close unless @stdin.closed?
  end

  def wait_until(timeout:)
    finished = false
    deadline = monotonic_time + timeout
    loop do
      if yield
        finished = true
        return :condition
      end
      unless alive?
        finished = true
        return :complete
      end
      if monotonic_time >= deadline
        finished = true
        return :timeout
      end
      sleep [deadline - monotonic_time, 0.02].min
    end
  ensure
    close unless finished
  end

  def result(timeout:, timeout_diagnostic:)
    finished = false
    timed_out = !wait_for_exit(timeout)
    terminate if timed_out
    @result ||= finalized_result(timed_out ? timeout_diagnostic : nil)
    finished = true
    @result
  ensure
    close unless finished
  end

  def force_kill
    finished = false
    signal_group("KILL")
    terminate_scoped_processes
    wait_for_exit(ROLE_COMMAND_KILL_GRACE_SECONDS)
    @result ||= finalized_result(nil)
    finished = true
    @result
  ensure
    close unless finished
  end

  def close
    return if @closed
    begin
      terminate if alive?
      terminate_scoped_processes
    ensure
      [@stdin, @stdout, @stderr].each { |pipe| pipe.close unless pipe.closed? }
      [@stdout_reader, @stderr_reader].each do |reader|
        reader.join(ROLE_COMMAND_KILL_GRACE_SECONDS)
        reader.kill if reader.alive?
        reader.join(ROLE_COMMAND_KILL_GRACE_SECONDS)
      end
      @closed = true
    end
  end

  private

  def alive?
    @waiter.alive? || @stdout_reader.alive? || @stderr_reader.alive?
  end

  def wait_for_exit(seconds)
    deadline = monotonic_time + seconds
    loop do
      return true unless alive?
      remaining = deadline - monotonic_time
      return false if remaining <= 0
      sleep [remaining, 0.02].min
    end
  end

  def terminate
    signal_group("TERM")
    unless wait_for_exit(ROLE_COMMAND_TERM_GRACE_SECONDS)
      signal_group("KILL")
      terminate_scoped_processes
      wait_for_exit(ROLE_COMMAND_KILL_GRACE_SECONDS)
    end
    unless @waiter.join(ROLE_COMMAND_KILL_GRACE_SECONDS)
      signal_group("KILL")
      raise ROLE_COMMAND_TIMEOUT_DIAGNOSTIC unless
        @waiter.join(ROLE_COMMAND_KILL_GRACE_SECONDS)
    end
    terminate_scoped_processes
  end

  def finalized_result(diagnostic)
    unless @waiter.join(ROLE_COMMAND_KILL_GRACE_SECONDS)
      signal_group("KILL")
      raise ROLE_COMMAND_TIMEOUT_DIAGNOSTIC unless
        @waiter.join(ROLE_COMMAND_KILL_GRACE_SECONDS)
    end
    [@stdout_reader, @stderr_reader].each do |reader|
      reader.join(ROLE_COMMAND_KILL_GRACE_SECONDS)
    end
    [@stdout, @stderr].each { |pipe| pipe.close unless pipe.closed? }
    [@stdout_reader, @stderr_reader].each do |reader|
      raise ROLE_COMMAND_TIMEOUT_DIAGNOSTIC unless
        reader.join(ROLE_COMMAND_KILL_GRACE_SECONDS)
    end
    stderr_text = @stderr_reader.value
    if diagnostic
      stderr_text += "\n" unless stderr_text.empty? || stderr_text.end_with?("\n")
      stderr_text += diagnostic
    end
    @closed = true
    [@stdout_reader.value, stderr_text, @waiter.value]
  end

  def drain(pipe)
    Thread.new do
      output = +""
      loop { output << pipe.readpartial(16 * 1024) }
    rescue EOFError, IOError
      output
    end
  end

  def signal_group(signal)
    Process.kill(signal, -@waiter.pid)
  rescue Errno::ESRCH
    nil
  end

  def terminate_scoped_processes
    return unless @process_scope
    deadline = monotonic_time + ROLE_COMMAND_KILL_GRACE_SECONDS
    loop do
      table, = Open3.capture2("ps", "-Ao", "pid=,ppid=,command=")
      processes = table.lines.filter_map do |line|
        pid_text, parent_text, command = line.strip.split(/\s+/, 3)
        next unless pid_text && parent_text && command
        [pid_text.to_i, parent_text.to_i, command]
      end
      parents = processes.to_h { |pid, parent, _command| [pid, parent] }
      victims = processes.filter_map do |pid, _parent, command|
        pid if command.include?(@process_scope)
      end
      victims.each do |pid|
        parent = parents[pid]
        while parent && parent > 1 && parent != Process.pid && !victims.include?(parent)
          victims << parent
          parent = parents[parent]
        end
      end
      victims.reject! { |pid| pid == Process.pid }
      return if victims.empty?
      begin
        Process.kill("KILL", *victims)
      rescue Errno::ESRCH
        nil
      end
      break if monotonic_time >= deadline
      sleep 0.02
    end
    raise ROLE_COMMAND_TIMEOUT_DIAGNOSTIC
  end

  def monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

class Fixture
  attr_reader :root, :protected, :controller, :crontab, :sha, :fsmonitor_marker

  def initialize(interpreter)
    @interpreter = interpreter
    @root = Dir.mktmpdir("production-auto-deploy-role.", Dir.home)
    File.chmod(0o700, @root)
    config_root = File.join(@root, ".config")
    FileUtils.mkdir_p(config_root, mode: 0o700)
    File.chmod(0o700, config_root)
    @protected = File.join(config_root, "nas-platform")
    FileUtils.mkdir_p(@protected, mode: 0o700)
    write_protected("vault.yml", "$ANSIBLE_VAULT;1.1;AES256\nfixture\n")
    write_protected("vault-password", "role-test-password\n")
    @private_root = File.join(@root, ".local", "share", "nas-platform")
    FileUtils.mkdir_p(@private_root, mode: 0o700)
    [File.join(@root, ".local"), File.join(@root, ".local", "share"), @private_root].each do |path|
      File.chmod(0o700, path)
    end
    @controller = File.join(@private_root, "controller")
    seed_controller
    @fake_bin = File.join(@root, "fake-bin")
    FileUtils.mkdir_p(@fake_bin, mode: 0o700)
    @crontab = File.join(@root, "crontab")
    write_fake_crontab
  end

  def close
    FileUtils.remove_entry_secure(@root) if File.exist?(@root)
  end

  def write_protected(name, content)
    path = File.join(@protected, name)
    File.write(path, content, mode: "w", perm: 0o600)
    File.chmod(0o600, path)
    path
  end

  def variables(extra = {}, controller_default: false)
    variables = {
      "platform_kind" => "nas",
      "platform_release_id" => @sha,
      "platform_vault_file" => File.join(@protected, "vault.yml"),
      "platform_public_host" => NAS_ADDRESS,
      "platform_callback_host" => NAS_ADDRESS,
      "vault_ntfy_dozzle_token" => TOKEN,
      "production_auto_deploy_test_mode" => true,
      "production_auto_deploy_test_root" => @root,
      "production_auto_deploy_test_trusted_owner_uid" => Process.euid
    }
    variables["production_auto_deploy_controller_python"] = @interpreter unless controller_default
    variables.merge(extra)
  end

  def run(extra = {}, check: false, controller_default: false, ansible_command: nil,
          environment: {}, extra_arguments: [], command_timeout: ROLE_COMMAND_TIMEOUT_SECONDS)
    play = role_play(extra, controller_default: controller_default)
    play_path = File.join(@root, "play-#{Thread.current.object_id}.yml")
    File.write(play_path, YAML.dump(play), mode: "w", perm: 0o600)
    args = Array(ansible_command || "ansible-playbook") +
           ["-i", "localhost,", "-c", "local", play_path]
    args.concat(extra_arguments)
    args << "--check" if check
    bounded_capture3(
      { "ANSIBLE_NOCOLOR" => "1" }.merge(environment),
      *args,
      chdir: ROOT,
      timeout: command_timeout
    )
  ensure
    File.unlink(play_path) if play_path && File.exist?(play_path)
  end

  def kill_at_power_boundary(extra, marker, ansible_command: "ansible-playbook",
                             environment: {}, marker_timeout: 30)
    play_path = File.join(@root, "power-play-#{Thread.current.object_id}.yml")
    File.write(play_path, YAML.dump(role_play(extra)), mode: "w", perm: 0o600)
    args = Array(ansible_command) + ["-i", "localhost,", "-c", "local", play_path]
    child = ManagedChild.new(
      { "ANSIBLE_NOCOLOR" => "1" }.merge(environment),
      *args,
      chdir: ROOT,
      process_scope: @root
    )
    child.close_stdin
    outcome = child.wait_until(timeout: marker_timeout) { File.exist?(marker) }
    reached = outcome == :condition
    stdout, stderr, status = if reached
                               child.force_kill
                             else
                               child.result(
                                 timeout: 0,
                                 timeout_diagnostic: POWER_BOUNDARY_TIMEOUT_DIAGNOSTIC
                               )
                             end
    [reached, stdout, stderr, status]
  ensure
    child&.close
    File.unlink(play_path) if play_path && File.exist?(play_path)
  end

  def role_play(extra = {}, controller_default: false)
    [{
      "hosts" => "localhost",
      "gather_facts" => true,
      "environment" => {
        "PATH" => "#{@fake_bin}:/usr/bin:/bin",
        "PRODUCTION_AUTO_DEPLOY_TEST_CRONTAB" => @crontab
      },
      "vars" => variables(extra, controller_default: controller_default),
      "roles" => ["production_auto_deploy"]
    }]
  end

  def write_process_secret_recorder
    marker = File.join(@root, "controller-process-secret-leak")
    recorder = File.join(@root, "process-secret-recorder")
    FileUtils.mkdir_p(recorder, mode: 0o700)
    File.chmod(0o700, recorder)
    source = <<~PY
      import os
      import pathlib
      import sys

      token = #{TOKEN.inspect}.encode()
      observed = b"\\0".join(os.fsencode(value) for value in sys.argv)
      observed += b"\\0" + b"\\0".join(
          os.fsencode(key) + b"=" + os.fsencode(value)
          for key, value in os.environ.items()
      )
      for proc_path in ("/proc/self/cmdline", "/proc/self/environ"):
          try:
              observed += b"\\0" + pathlib.Path(proc_path).read_bytes()
          except OSError:
              pass
      if token in observed:
          pathlib.Path(#{marker.inspect}).write_text("secret observed")
    PY
    File.write(File.join(recorder, "sitecustomize.py"), source, mode: "w", perm: 0o600)
    [recorder, marker]
  end

  def write_sealed_ansible_runtime(ansible_playbook)
    binary_root = File.join(@private_root, "tooling", "sealed", "venv", "bin")
    FileUtils.mkdir_p(binary_root, mode: 0o700)
    [File.join(@private_root, "tooling"), File.join(@private_root, "tooling", "sealed"),
     File.join(@private_root, "tooling", "sealed", "venv"), binary_root].each do |path|
      File.chmod(0o700, path)
    end
    ansible_python = File.open(ansible_playbook, &:readline).delete_prefix("#!").strip
    ansible_site, ansible_site_error, ansible_site_status = Open3.capture3(
      ansible_python,
      "-c",
      "import pathlib, ansible; print(pathlib.Path(ansible.__file__).parent.parent)"
    )
    raise "could not locate the sealed Ansible package: #{ansible_site_error}" unless
      ansible_site_status.success?
    sealed_python = File.join(binary_root, "python")
    FileUtils.cp(@interpreter, sealed_python)
    File.chmod(0o700, sealed_python)
    sealed_ansible = File.join(binary_root, "ansible-playbook")
    File.write(
      sealed_ansible,
      "from ansible.cli.playbook import main\nraise SystemExit(main())\n",
      mode: "w",
      perm: 0o600
    )
    File.chmod(0o600, sealed_ansible)
    [[sealed_python, sealed_ansible], sealed_python, ansible_site.strip]
  end

  def automatic_interpreter_arguments(controller_python, sealed_ansible)
    source = <<~PY
      import importlib.util
      import json
      from pathlib import Path
      import sys
      from types import SimpleNamespace

      poller, controller, ansible, vault, password = sys.argv[1:]
      spec = importlib.util.spec_from_file_location("automatic_poller", poller)
      module = importlib.util.module_from_spec(spec)
      sys.modules[spec.name] = module
      spec.loader.exec_module(module)
      config = SimpleNamespace(
          controller_python=Path(controller),
          vault_file=Path(vault),
          vault_password_file=Path(password),
      )
      tooling = module.Tooling(
          ansible_playbook=Path(ansible),
          python=Path(controller),
          collections=Path(controller).parent,
      )
      arguments = module._playbook_arguments(
          config,
          tooling,
          "install-production-auto-deploy.yml",
          inventory=True,
          controller_python=Path(controller),
      )
      pins = [
          argument for argument in arguments
          if argument.startswith("ansible_python_interpreter=")
      ]
      if pins != [f"ansible_python_interpreter={controller}"]:
          raise SystemExit("automatic interpreter pin is ambiguous")
      print(json.dumps(["-e", pins[0]]))
    PY
    stdout, stderr, status = Open3.capture3(
      @interpreter,
      "-c",
      source,
      POLLER_SOURCE,
      controller_python,
      sealed_ansible.last,
      File.join(@protected, "vault.yml"),
      File.join(@protected, "vault-password")
    )
    raise "automatic interpreter arguments failed: #{stderr}" unless status.success?
    JSON.parse(stdout)
  end

  def managed_paths
    {
      launcher: File.join(@root, ".local", "bin", "nas-platform-deploy"),
      current: File.join(@root, ".local", "libexec", "nas-platform", "current"),
      poller: File.join(@root, ".local", "libexec", "nas-platform", "current", "production_auto_deploy.py"),
      generations: File.join(@root, ".local", "libexec", "nas-platform", "generations"),
      config: File.join(@protected, "deployer.json"),
      notifier: File.join(@protected, "ntfy.curl"),
      tooling: File.join(@private_root, "tooling"),
      state: File.join(@private_root, "state"),
      logs: File.join(@private_root, "logs")
    }
  end

  def rewrite_active_generation(launcher: false, config: false, notifier: false,
                                hostile_launcher: false)
    paths = managed_paths
    current = File.readlink(paths.fetch(:current))
    generation = File.expand_path(current, File.dirname(paths.fetch(:current)))
    assets = {
      "nas-platform-deploy" => File.binread(paths.fetch(:launcher)),
      "production_auto_deploy.py" => File.binread(File.join(generation, "production_auto_deploy.py")),
      "deployer.json" => File.binread(File.join(generation, "deployer.json")),
      "ntfy.curl" => File.binread(File.join(generation, "ntfy.curl"))
    }
    if launcher
      assets["nas-platform-deploy"] = <<~SH
        #!/bin/sh
        set -eu

        generation_root="#{paths.fetch(:generations)}"
        active_generation=$(
          CDPATH= cd -P -- "#{paths.fetch(:current)}"
          pwd -P
        )
        generation_name=${active_generation##*/}
        case "$generation_name" in
          ''|*[!0-9a-f]*) exit 1 ;;
        esac
        name_length=0
        remaining_name=$generation_name
        while [ -n "$remaining_name" ]; do
          name_length=$((name_length + 1))
          remaining_name=${remaining_name#?}
        done
        [ "$name_length" -eq 64 ] || exit 1
        [ "$active_generation" = "$generation_root/$generation_name" ] || exit 1

        exec "$active_generation/production_auto_deploy.py" \\
          --config "$active_generation/deployer.json" "$@"
      SH
    end
    if hostile_launcher
      assets["nas-platform-deploy"] = assets.fetch("nas-platform-deploy").sub(
        "\nexec ",
        "\nexit 0\nexec "
      )
    end
    if config
      payload = JSON.parse(assets.fetch("deployer.json"))
      assets["deployer.json"] = JSON.pretty_generate(payload) + "\n"
    end
    if notifier
      assets["ntfy.curl"] = assets.fetch("ntfy.curl").sub(TOKEN, "prior-token")
    end
    digest = Digest::SHA256.new
    assets.each do |name, bytes|
      digest.update([name.bytesize].pack("n"))
      digest.update(name)
      digest.update(bytes)
    end
    replacement = File.join(paths.fetch(:generations), digest.hexdigest)
    FileUtils.mkdir_p(replacement, mode: 0o700)
    File.chmod(0o700, replacement)
    {
      "nas-platform-deploy" => 0o700,
      "production_auto_deploy.py" => 0o700,
      "deployer.json" => 0o600,
      "ntfy.curl" => 0o600
    }.each do |name, mode|
      File.write(File.join(replacement, name), assets.fetch(name), mode: "wb", perm: mode)
      File.chmod(mode, File.join(replacement, name))
    end
    File.unlink(paths.fetch(:current))
    File.symlink("generations/#{digest.hexdigest}", paths.fetch(:current))
  end

  def make_controller_hostile(kind)
    git_directory = File.join(@controller, ".git")
    case kind
    when :gitmodules
      File.write(File.join(@controller, ".gitmodules"), "[submodule \"x\"]\n\tpath = x\n\turl = ./x\n")
      commit_controller_change("hostile gitmodules", ".gitmodules")
    when :gitlink
      run_git("checkout", "main")
      run_git("update-index", "--add", "--cacheinfo", "160000,#{@sha},vendor/sub")
      run_git("commit", "-m", "hostile gitlink")
      publish_controller_head
    when :symlink_tree
      File.symlink("fixture", File.join(@controller, "linked"))
      commit_controller_change("hostile symlink", "linked")
    when :replace
      replacement = run_git("commit-tree", "HEAD^{tree}", "-p", @sha, "-m", "replacement").strip
      run_git("replace", @sha, replacement)
    when :grafts
      FileUtils.mkdir_p(File.join(git_directory, "info"))
      File.write(File.join(git_directory, "info", "grafts"), "#{@sha}\n")
    when :shallow
      File.write(File.join(git_directory, "shallow"), "#{@sha}\n")
    when :commondir
      File.write(File.join(git_directory, "commondir"), ".\n")
    when :core_worktree
      external = File.join(@root, "external-worktree")
      FileUtils.mkdir_p(external, mode: 0o700)
      run_git("config", "core.worktree", external)
    when :fsmonitor
      @fsmonitor_marker = File.join(@root, "fsmonitor-executed")
      fsmonitor = File.join(@root, "hostile-fsmonitor")
      File.write(
        fsmonitor,
        "#!/bin/sh\nprintf executed > #{@fsmonitor_marker}\nprintf '\\n'\n",
        mode: "w",
        perm: 0o700
      )
      File.chmod(0o700, fsmonitor)
      run_git("config", "core.fsmonitor", fsmonitor)
    when :wrong_remote
      run_git("remote", "set-url", "origin", "https://github.com/example/other.git")
    when :dirty
      File.write(File.join(@controller, "fixture"), "dirty\n")
    else
      raise "unknown hostile controller kind: #{kind}"
    end
  end

  private

  def bounded_capture3(environment, *args, chdir:, timeout:)
    child = ManagedChild.new(environment, *args, chdir: chdir, process_scope: @root)
    child.close_stdin
    child.result(timeout: timeout, timeout_diagnostic: ROLE_COMMAND_TIMEOUT_DIAGNOSTIC)
  ensure
    child&.close
  end

  def commit_controller_change(message, path)
    run_git("checkout", "main")
    run_git("add", path)
    run_git("commit", "-m", message)
    publish_controller_head
  end

  def publish_controller_head
    @sha = run_git("rev-parse", "HEAD").strip
    run_git("update-ref", "refs/remotes/origin/main", @sha)
    run_git("checkout", "--detach", @sha)
  end

  def seed_controller
    FileUtils.mkdir_p(@controller, mode: 0o700)
    run_git("init", "-b", "main")
    run_git("config", "user.email", "role-test@example.invalid")
    run_git("config", "user.name", "Role Test")
    File.write(File.join(@controller, "fixture"), "controller\n", mode: "w", perm: 0o600)
    run_git("add", "fixture")
    run_git("commit", "-m", "fixture")
    @sha = run_git("rev-parse", "HEAD").strip
    run_git("remote", "add", "origin", REPOSITORY_URL)
    run_git("update-ref", "refs/remotes/origin/main", @sha)
    run_git("checkout", "--detach", @sha)
    File.chmod(0o700, @controller)
  end

  def run_git(*args)
    stdout, stderr, status = Open3.capture3("/usr/bin/git", "-C", @controller, *args)
    raise "git fixture failed: #{stderr}" unless status.success?
    stdout
  end

  def write_fake_crontab
    script = <<~SH
      #!/bin/sh
      set -eu
      state=${PRODUCTION_AUTO_DEPLOY_TEST_CRONTAB:?}
      if [ "${1-}" = "-l" ]; then
        [ -f "$state" ] || exit 1
        cat "$state"
        exit 0
      fi
      if [ "${1-}" = "-r" ]; then
        rm -f "$state"
        exit 0
      fi
      last=""
      for argument in "$@"; do last=$argument; done
      if [ "$last" = "-" ]; then
        umask 077
        cat > "$state"
      elif [ -n "$last" ]; then
        umask 077
        cp "$last" "$state"
      else
        exit 2
      fi
    SH
    path = File.join(@fake_bin, "crontab")
    File.write(path, script, mode: "w", perm: 0o700)
    File.chmod(0o700, path)
  end
end

def with_fixture(interpreter)
  fixture = Fixture.new(interpreter)
  yield fixture
ensure
  fixture&.close
end

def snapshot(root)
  Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
    .reject { |path| [".", ".."].include?(File.basename(path)) }
    .to_h { |path| [path.delete_prefix("#{root}/"), File.symlink?(path) ? [:link, File.readlink(path)] : [File.ftype(path), File.stat(path).mode & 0o777, File.file?(path) ? File.binread(path) : nil]] }
end

def write_term_resistant_tree(fixture, interpreter, label, escape_group: false)
  ready = File.join(fixture.root, "#{label}-ready")
  marker = File.join(fixture.root, "#{label}-delayed-marker")
  descendant = File.join(fixture.root, "#{label}-descendant")
  File.write(
    descendant,
    <<~PYTHON,
      #!#{interpreter}
      import os
      import pathlib
      import signal
      import time

      #{escape_group ? "os.setsid()" : ""}
      signal.signal(signal.SIGTERM, signal.SIG_IGN)
      pathlib.Path(os.environ["MANAGED_CHILD_READY"]).write_text("ready")
      time.sleep(3)
      pathlib.Path(os.environ["MANAGED_CHILD_MARKER"]).write_text("orphaned")
    PYTHON
    mode: "w",
    perm: 0o700
  )
  File.chmod(0o700, descendant)
  command = File.join(fixture.root, "#{label}-command")
  File.write(
    command,
    <<~SH,
      #!/bin/sh
      trap '' TERM
      "#{descendant}" &
      while :; do wait || true; done
    SH
    mode: "w",
    perm: 0o700
  )
  File.chmod(0o700, command)
  [command, ready, marker]
end

def start_test_poll(fixture, interpreter, entered:, release: nil, attempted: nil,
                    command: nil, environment: {})
  return ManagedChild.new(environment, *command, process_scope: fixture.root) if command

  current = fixture.managed_paths.fetch(:current)
  generation = File.expand_path(File.readlink(current), File.dirname(current))
  poller = File.join(generation, "production_auto_deploy.py")
  config = File.join(generation, "deployer.json")
  wait_source = if release
                  <<~PY
                    pathlib.Path(#{entered.inspect}).write_text("entered")
                    while not pathlib.Path(#{release.inspect}).exists():
                        time.sleep(0.02)
                  PY
                else
                  "pathlib.Path(#{attempted.inspect}).write_text('attempted')\n"
                end
  source = <<~PY
    import importlib.util, pathlib, sys, time
    spec = importlib.util.spec_from_file_location("installed_poller", #{poller.inspect})
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    sha = #{LOCK_TEST_SHA.inspect}
    module._validate_controller_python = lambda config: config.controller_python
    module.resolve_main_sha = lambda config: sha
    module.fetch_ci_runs = lambda config, head: (module.CiRun(
        head_sha=sha, status="completed", conclusion="success", event="push",
        head_branch="main", name="CI"),)
    def attempt(config, candidate):
    #{wait_source.lines.map { |line| "    #{line}" }.join.rstrip}
        return True
    module.attempt_candidate = attempt
    raise SystemExit(module.main(["--config", #{config.inspect}, "--poll"]))
  PY
  ManagedChild.new(environment, interpreter, "-c", source, process_scope: fixture.root)
end

failures = []
suite_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
suite_main_thread = Thread.current
suite_watchdog = Thread.new do
  sleep ROLE_SUITE_BUDGET_SECONDS
  suite_main_thread.raise(RuntimeError, ROLE_SUITE_TIMEOUT_DIAGNOSTIC)
end
suite_watchdog.report_on_exception = false

runner_parameters = Fixture.instance_method(:run).parameters
failures << "role runner does not expose a testable per-command deadline" unless
  runner_parameters.include?([:key, :command_timeout])
role_test_source = File.read(__FILE__)
failures << "asynchronous children do not have one managed spawn owner" unless
  defined?(ManagedChild) &&
  role_test_source.scan(["Open3", "popen3"].join(".")).length == 1 &&
  role_test_source.scan(["@waiter", "value"].join(".")).length == 1 &&
  role_test_source.scan(["Process", "spawn"].join(".")).empty?

required = [ROLE_TASKS, ROLE_DEFAULTS, ROLE_ARGUMENTS, INSTALL_PLAY, LAUNCHER_SOURCE]
missing = required.reject { |path| File.file?(path) }
failures << "installer files are absent: #{missing.join(', ')}" unless missing.empty?

unless missing.empty?
  warn failures.join("\n")
  exit 1
end

tasks_text = File.read(ROLE_TASKS)
play = YAML.safe_load_file(INSTALL_PLAY)
failures << "notifier rendering is not protected by no_log" unless
  tasks_text.match?(/Render protected ntfy curl configuration.*?no_log:\s*true/m)
failures << "role does not reject a root effective account" unless
  tasks_text.include?("production_auto_deploy_effective_uid | int != 0")
failures << "role does not validate trusted executable ownership" unless
  tasks_text.include?("trusted executable") && tasks_text.include?("st_uid")
failures << "role does not enforce controller Python 3.12" unless tasks_text.include?("3.12")
failures << "role does not serialize installers with one kernel lock" unless
  tasks_text.include?("fcntl.flock") && tasks_text.include?(".deployment.lock.identity") &&
  tasks_text.include?("production_auto_deploy_inherited_lock")
failures << "role does not atomically switch one versioned current pointer" unless
  tasks_text.include?("generations/") && tasks_text.include?("os.replace(temporary_link, current)")
failures << "install play does not target platform_hosts with facts" unless
  play.is_a?(Array) && play.one? && play[0]["hosts"] == "platform_hosts" && play[0]["gather_facts"] == true
role_names = Array(play&.dig(0, "roles")).map { |entry| entry.is_a?(Hash) ? entry["role"] : entry }
failures << "install play must contain only production_auto_deploy" unless role_names == ["production_auto_deploy"]
pre_tasks = Array(play&.dig(0, "pre_tasks"))
failures << "install play must validate vault_contract first with no_log" unless
  pre_tasks.first.to_s.include?("vault_contract") && pre_tasks.first.to_s.include?("no_log")

with_fixture(interpreter) do |fixture|
  normal_command = File.join(fixture.root, "normal-command")
  File.write(
    normal_command,
    "#!/bin/sh\nprintf normal-out\nprintf normal-err >&2\nexit 23\n",
    mode: "w",
    perm: 0o700
  )
  File.chmod(0o700, normal_command)
  stdout, stderr, status = fixture.run(ansible_command: normal_command, command_timeout: 2)
  failures << "bounded role runner changed normal stdout" unless stdout == "normal-out"
  failures << "bounded role runner changed normal stderr" unless stderr == "normal-err"
  failures << "bounded role runner changed normal exit status" unless status.exitstatus == 23

  hung_command, ready, marker = write_term_resistant_tree(
    fixture, interpreter, "hung-runner"
  )
  started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  stdout, stderr, status = fixture.run(
    ansible_command: hung_command,
    environment: {
      "MANAGED_CHILD_MARKER" => marker,
      "MANAGED_CHILD_READY" => ready
    },
    command_timeout: 1
  )
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
  failures << "bounded role runner did not start its TERM-resistant descendant" unless
    File.exist?(ready)
  failures << "bounded role runner did not terminate a hung process group" unless
    elapsed < 3 && status.signaled?
  failures << "bounded role runner changed timed-out stdout" unless stdout.empty?
  failures << "bounded role runner emitted a variable or unsafe timeout diagnostic" unless
    stderr == ROLE_COMMAND_TIMEOUT_DIAGNOSTIC
  sleep 2
  failures << "bounded role runner left a descendant able to write after timeout" if
    File.exist?(marker)
  process_table, = Open3.capture2("ps", "-Ao", "command=")
  failures << "bounded role runner left an orphaned fixture process" if
    process_table.lines.any? { |line| line.include?(fixture.root) }
end

if defined?(ManagedChild)
  with_fixture(interpreter) do |fixture|
    environment = lambda do |ready, marker|
      {
        "MANAGED_CHILD_READY" => ready,
        "MANAGED_CHILD_MARKER" => marker
      }
    end

    command, ready, delayed_marker = write_term_resistant_tree(
      fixture, interpreter, "missing-power-marker", escape_group: true
    )
    reached, stdout, stderr, status = fixture.kill_at_power_boundary(
      {},
      File.join(fixture.root, "power-marker-never-written"),
      ansible_command: command,
      environment: environment.call(ready, delayed_marker),
      marker_timeout: 1
    )
    failures << "missing power marker unexpectedly succeeded" if reached
    failures << "missing power marker did not start its resistant descendant" unless
      File.exist?(ready)
    failures << "missing power marker did not return a failed child" unless
      status.signaled?
    failures << "missing power marker changed timed-out stdout" unless stdout.empty?
    failures << "missing power marker emitted an unsafe diagnostic" unless
      stderr == POWER_BOUNDARY_TIMEOUT_DIAGNOSTIC
    sleep 1.2
    failures << "power-boundary timeout left a delayed descendant" if
      File.exist?(delayed_marker)

    command, ready, delayed_marker = write_term_resistant_tree(
      fixture, interpreter, "watchdog-interruption"
    )
    interrupter = Thread.new do
      sleep 1
      Thread.main.raise(RuntimeError, ROLE_SUITE_TIMEOUT_DIAGNOSTIC)
    end
    watchdog_error = begin
      fixture.kill_at_power_boundary(
        {},
        File.join(fixture.root, "watchdog-power-marker"),
        ansible_command: command,
        environment: environment.call(ready, delayed_marker),
        marker_timeout: 5
      )
      nil
    rescue RuntimeError => error
      error
    ensure
      interrupter.join
    end
    failures << "watchdog did not interrupt the managed child wait" unless
      watchdog_error&.message == ROLE_SUITE_TIMEOUT_DIAGNOSTIC
    failures << "watchdog test did not start its resistant descendant" unless File.exist?(ready)
    sleep 1.2
    failures << "watchdog interruption left a delayed descendant" if File.exist?(delayed_marker)

    command, ready, delayed_marker = write_term_resistant_tree(
      fixture, interpreter, "poll-timeout"
    )
    poll = start_test_poll(
      fixture,
      interpreter,
      entered: File.join(fixture.root, "unused-poll-entry"),
      command: [command],
      environment: environment.call(ready, delayed_marker)
    )
    poll.close_stdin
    ready_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    sleep 0.02 until File.exist?(ready) ||
                     Process.clock_gettime(Process::CLOCK_MONOTONIC) >= ready_deadline
    poll_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stdout, stderr, status = poll.result(
      timeout: 0.3,
      timeout_diagnostic: POLL_CHILD_TIMEOUT_DIAGNOSTIC
    )
    poll_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - poll_started_at
    failures << "poll timeout did not start its resistant descendant" unless File.exist?(ready)
    failures << "poll timeout did not return a failed child" unless status.signaled?
    failures << "poll timeout did not bound the never-exiting child" unless poll_elapsed < 2
    failures << "poll timeout changed stdout" unless stdout.empty?
    failures << "poll timeout emitted an unsafe diagnostic" unless
      stderr == POLL_CHILD_TIMEOUT_DIAGNOSTIC
    poll.close
    sleep 1.8
    failures << "poll timeout left a delayed descendant" if File.exist?(delayed_marker)

    process_table, = Open3.capture2("ps", "-Ao", "command=")
    failures << "managed child regressions left an orphaned fixture process" if
      process_table.lines.any? { |line| line.include?(fixture.root) }
  ensure
    poll&.close
  end
end

with_fixture(interpreter) do |fixture|
  sealed_ansible, sealed_python, ansible_site = fixture.write_sealed_ansible_runtime(ansible)
  trusted_target_python = File.join(fixture.root, "trusted-target-python")
  FileUtils.cp(interpreter, trusted_target_python)
  File.chmod(0o700, trusted_target_python)
  automatic_arguments = fixture.automatic_interpreter_arguments(
    trusted_target_python,
    sealed_ansible
  )
  stdout, stderr, status = fixture.run(
    {},
    controller_default: true,
    ansible_command: sealed_ansible,
    environment: { "PYTHONPATH" => ansible_site },
    extra_arguments: automatic_arguments
  )
  failures << "sealed-venv Ansible fixture failed: #{(stdout + stderr).lines.last(16).join}" unless
    status.success?
  next unless status.success?

  config = JSON.parse(File.read(fixture.managed_paths.fetch(:config)))
  failures << "sealed-venv Ansible became the trusted controller runtime" if
    config["controller_python"] == sealed_python
  failures << "role did not select the independently trusted target Python" unless
    config["controller_python"] == trusted_target_python
  failures << "installed poller did not pin the independently trusted target Python" unless
    File.open(fixture.managed_paths.fetch(:poller), &:readline).strip == "#!#{trusted_target_python}"
end

with_fixture(interpreter) do |fixture|
  recorder, marker = fixture.write_process_secret_recorder
  recorder_environment = { "PYTHONPATH" => recorder }
  stdout, stderr, status = fixture.run({}, environment: recorder_environment)
  failures << "process-secret recorder fixture failed: #{(stdout + stderr).lines.last(16).join}" unless
    status.success?
  failures << "notifier token appeared in validator argv, environment, or proc view" if
    File.exist?(marker)
  failures << "notifier token appeared in successful installer output" if
    (stdout + stderr).include?(TOKEN)
  next unless status.success?

  %w[candidate_syntax after_generation before_current after_current after_cron].each do |boundary|
    File.unlink(marker) if File.exist?(marker)
    failure_stdout, failure_stderr, failure_status = fixture.run({
      "production_auto_deploy_test_fail_activation" => boundary
    }, environment: recorder_environment)
    failures << "process-secret #{boundary} failure unexpectedly succeeded" if
      failure_status.success?
    failures << "notifier token appeared in #{boundary} argv, environment, or proc view" if
      File.exist?(marker)
    failures << "notifier token appeared in #{boundary} installer output" if
      (failure_stdout + failure_stderr).include?(TOKEN)
  end
end

with_fixture(interpreter) do |fixture|
  before = snapshot(fixture.root)
  _stdout, stderr, status = fixture.run({ "platform_kind" => "mac" })
  failures << "non-NAS role invocation succeeded" if status.success?
  failures << "non-NAS failure omitted its fixed diagnostic" unless (stdout = _stdout + stderr).include?("NAS-only")
  failures << "non-NAS failure mutated the disposable root" unless snapshot(fixture.root) == before
end

with_fixture(interpreter) do |fixture|
  before = snapshot(fixture.root)
  _stdout, stderr, status = fixture.run({
    "production_auto_deploy_test_identity" => {
      "uid" => 0, "gid" => 0, "user" => "root", "home" => "/var/root"
    }
  })
  failures << "root role invocation succeeded" if status.success?
  failures << "root failure omitted its fixed diagnostic" unless (_stdout + stderr).include?("non-root")
  failures << "root failure mutated the disposable root" unless snapshot(fixture.root) == before
end

with_fixture(interpreter) do |fixture|
  before = snapshot(fixture.root)
  stdout, stderr, status = fixture.run({}, check: true)
  failures << "check mode failed: #{(stdout + stderr).lines.last(16).join}" unless status.success?
  failures << "check mode did not plan the installation" unless (stdout + stderr).include?("Plan poller activation")
  failures << "check mode created managed paths" unless fixture.managed_paths.values.none? { |path| File.exist?(path) || File.symlink?(path) }
  failures << "check mode mutated existing inputs" unless snapshot(fixture.root) == before
end

with_fixture(interpreter) do |fixture|
  stdout, stderr, status = fixture.run
  failures << "real-Ansible installation failed: #{(stdout + stderr).lines.last(24).join}" unless status.success?
  next unless status.success?
  paths = fixture.managed_paths
  %i[tooling state logs generations].each do |name|
    path = paths.fetch(name)
    failures << "#{name} directory is absent or not 0700" unless
      File.directory?(path) && (File.stat(path).mode & 0o777) == 0o700
  end
  failures << "current is not one relative atomic generation pointer" unless
    File.symlink?(paths.fetch(:current)) &&
    File.readlink(paths.fetch(:current)).match?(%r{\Agenerations/[0-9a-f]{64}\z})
  expected_stable_links = {
    launcher: "../libexec/nas-platform/current/nas-platform-deploy",
    config: "../../.local/libexec/nas-platform/current/deployer.json",
    notifier: "../../.local/libexec/nas-platform/current/ntfy.curl"
  }
  expected_stable_links.each do |name, target|
    path = paths.fetch(name)
    failures << "#{name} is not the exact bootstrap-only managed symlink" unless
      File.symlink?(path) && File.readlink(path) == target
  end
  current_generation = File.expand_path(
    File.readlink(paths.fetch(:current)), File.dirname(paths.fetch(:current))
  )
  { "nas-platform-deploy" => 0o700, "production_auto_deploy.py" => 0o700,
    "deployer.json" => 0o600, "ntfy.curl" => 0o600 }.each do |name, mode|
    path = File.join(current_generation, name)
    failures << "generation #{name} is absent, linked, or has the wrong mode" unless
      File.file?(path) && !File.symlink?(path) && (File.stat(path).mode & 0o777) == mode
  end
  config = JSON.parse(File.read(paths.fetch(:config))) rescue {}
  expected_keys = %w[branch controller_python controller_root deployment_home github_api_base log_retention_count
                     log_retention_days log_root ntfy_curl_config platform_callback_host
                     platform_nas_address platform_public_host repository repository_url state_root
                     tooling_root vault_file vault_password_file workflow workflow_name]
  failures << "installed config schema differs" unless config.keys.sort == expected_keys.sort
  failures << "installed config contains a secret" if File.read(paths.fetch(:config)).include?(TOKEN) ||
                                                  File.read(paths.fetch(:config)).include?("role-test-password")
  failures << "GitHub API base is not exact" unless config["github_api_base"] == "https://api.github.com"
  failures << "controller_python differs from the validated interpreter" unless config["controller_python"] == interpreter
  failures << "deployment_home is not the exact validated home boundary" unless config["deployment_home"] == fixture.root
  notifier = File.read(paths.fetch(:notifier))
  failures << "notifier contract differs" unless notifier == <<~CURL
    url = "http://127.0.0.1:2586/nas-critical"
    header = "Authorization: Bearer #{TOKEN}"
    header = "Content-Type: application/json"
  CURL
  cron = File.read(fixture.crontab)
  launcher = paths.fetch(:launcher)
  failures << "cron is not one exact five-minute launcher poll" unless
    cron.scan("#Ansible: NAS platform production auto-deploy").length == 1 &&
    cron.lines.grep(/nas-platform-deploy/).map(&:strip) == ["*/5 * * * * #{launcher} --poll"]
  launcher_body = File.read(launcher)
  expected_launcher = <<~SH
    #!/bin/sh
    set -eu

    generation=$(
      CDPATH= cd -P -- "#{File.dirname(paths.fetch(:current))}/current"
      pwd -P
    )
    generation_name=${generation##*/}
    case "$generation_name" in
      ''|*[!0-9a-f]*) exit 1 ;;
    esac
    generation_length=0
    generation_tail=$generation_name
    while [ -n "$generation_tail" ]; do
      generation_length=$((generation_length + 1))
      generation_tail=${generation_tail#?}
    done
    [ "$generation_length" -eq 64 ] || exit 1
    [ "$generation" = "#{paths.fetch(:generations)}/$generation_name" ] || exit 1

    exec "$generation/production_auto_deploy.py" \\
      --config "$generation/deployer.json" "$@"
  SH
  failures << "launcher does not use literal installed paths" unless launcher_body == expected_launcher
  failures << "launcher shell syntax is invalid" unless system("/bin/sh", "-n", launcher)
  failures << "installed poller does not pin the validated controller interpreter" unless
    File.open(paths.fetch(:poller), &:readline).strip == "#!#{interpreter}"
  status_stdout, status_stderr, status_status = Open3.capture3(
    { "PATH" => "/ambient/path/is/forbidden", "HOME" => "/ambient/home/is/forbidden" },
    launcher, "--status"
  )
  failures << "stable launcher status failed without ambient PATH/HOME: #{status_stderr}" unless
    status_status.success?
  status_records = status_stdout.lines.map { |line| JSON.parse(line) } rescue []
  failures << "stable launcher status did not read the initialized deployment state" unless
    status_records.one? && status_records[0]["sha"] == fixture.sha &&
    status_records[0]["outcome"] == "success"

  second_stdout, second_stderr, second_status = fixture.run
  failures << "second role run failed: #{second_stderr.lines.last(8).join}" unless second_status.success?
  failures << "second role run was not idempotent" unless
    (second_stdout + second_stderr).match?(/changed=0\s+unreachable=0\s+failed=0/)

  previous = %i[launcher poller config notifier].to_h { |name| [name, File.binread(paths.fetch(name))] }
  previous_current = File.readlink(paths.fetch(:current))
  invalid = File.join(fixture.root, "invalid-candidate-poller.py")
  File.write(invalid, "def invalid(:\n", mode: "w", perm: 0o600)
  _stage_stdout, _stage_stderr, stage_status = fixture.run({
    "production_auto_deploy_test_poller_source" => invalid
  })
  failures << "invalid staged poller was accepted" if stage_status.success?
  previous.each do |name, bytes|
    failures << "staging failure changed #{name}" unless File.binread(paths.fetch(name)) == bytes
  end

  File.chmod(0o644, paths.fetch(:launcher))
  _mode_stdout, _mode_stderr, mode_status = fixture.run
  failures << "hostile installed launcher mode was accepted" if mode_status.success?
  File.chmod(0o700, paths.fetch(:launcher))

  File.write(paths.fetch(:launcher), "#!/bin/sh\nexit 0\n", mode: "w", perm: 0o700)
  hostile_launcher_snapshot = snapshot(fixture.root)
  _content_stdout, _content_stderr, content_status = fixture.run
  failures << "hostile stable launcher content was accepted" if content_status.success?
  failures << "hostile stable launcher failure mutated managed state" unless
    snapshot(fixture.root) == hostile_launcher_snapshot
  File.write(paths.fetch(:launcher), previous.fetch(:launcher), mode: "wb", perm: 0o700)
  File.chmod(0o700, paths.fetch(:launcher))

  bin_root = File.dirname(paths.fetch(:launcher))
  File.chmod(0o755, bin_root)
  _directory_stdout, _directory_stderr, directory_status = fixture.run
  failures << "hostile managed-directory mode was accepted" if directory_status.success?
  File.chmod(0o700, bin_root)

  config_target = File.join(fixture.protected, "external-config-target")
  File.write(config_target, previous.fetch(:config), mode: "wb", perm: 0o600)
  File.unlink(paths.fetch(:config))
  File.symlink(config_target, paths.fetch(:config))
  _link_stdout, _link_stderr, link_status = fixture.run
  failures << "hostile installed config symlink was accepted" if link_status.success?
  File.unlink(paths.fetch(:config))
  File.symlink(expected_stable_links.fetch(:config), paths.fetch(:config))

  safe_current = File.readlink(paths.fetch(:current))
  File.unlink(paths.fetch(:current))
  File.symlink("../../../../outside-generation", paths.fetch(:current))
  hostile_current_snapshot = snapshot(fixture.root)
  _current_stdout, _current_stderr, current_status = fixture.run
  failures << "escaping current generation pointer was accepted" if current_status.success?
  failures << "escaping current failure mutated managed state" unless
    snapshot(fixture.root) == hostile_current_snapshot
  File.unlink(paths.fetch(:current))
  File.symlink(safe_current, paths.fetch(:current))

  File.write(
    paths.fetch(:poller),
    previous.fetch(:poller) + "\n# hostile generation mutation\n",
    mode: "wb",
    perm: 0o700
  )
  hostile_generation_snapshot = snapshot(fixture.root)
  _generation_stdout, _generation_stderr, generation_status = fixture.run
  failures << "generation content not matching its identity was accepted" if generation_status.success?
  failures << "hostile generation failure mutated managed state" unless
    snapshot(fixture.root) == hostile_generation_snapshot
  File.write(paths.fetch(:poller), previous.fetch(:poller), mode: "wb", perm: 0o700)
  File.chmod(0o700, paths.fetch(:poller))

  fixture.rewrite_active_generation(launcher: true, config: true, notifier: true)
  previous = %i[launcher poller config notifier].to_h { |name| [name, File.binread(paths.fetch(name))] }
  previous_current = File.readlink(paths.fetch(:current))
  previous_cron = File.binread(fixture.crontab)
  alternate = File.join(fixture.root, "candidate-poller.py")
  File.write(alternate, File.binread(POLLER_SOURCE) + "\n# activation failure candidate\n", mode: "wb", perm: 0o600)
  %w[after_generation before_current after_current after_cron].each do |boundary|
    _failure_stdout, _failure_stderr, failure_status = fixture.run({
      "production_auto_deploy_test_poller_source" => alternate,
      "production_auto_deploy_test_fail_activation" => boundary
    })
    failures << "injected #{boundary} activation failure succeeded" if failure_status.success?
    failures << "#{boundary} failure switched current" unless
      File.readlink(paths.fetch(:current)) == previous_current
    previous.each do |name, bytes|
      failures << "#{boundary} failure did not restore #{name}" unless
        File.binread(paths.fetch(name)) == bytes
    end
    failures << "#{boundary} failure did not restore the exact crontab" unless
      File.binread(fixture.crontab) == previous_cron
    status_stdout, status_stderr, status_status = Open3.capture3(
      { "PATH" => "/hostile", "HOME" => "/hostile" }, launcher, "--status"
    )
    failures << "#{boundary} failure left a broken launcher: #{status_stderr}" unless
      status_status.success? && status_stdout.include?(fixture.sha)
  end
  failures << "prior generation was not retained for recovery" unless
    File.directory?(File.join(File.dirname(paths.fetch(:current)), previous_current))

  installer_result = nil
  installer = Thread.new do
    installer_result = fixture.run({ "production_auto_deploy_test_activation_delay" => 0.75 })
  end
  observed = []
  while installer.alive?
    output, error, process = Open3.capture3(
      { "PATH" => "/hostile", "HOME" => "/hostile" }, launcher, "--status"
    )
    observed << [output, error, process.success?]
  end
  installer.join
  _concurrent_stdout, concurrent_stderr, concurrent_status = installer_result
  failures << "concurrent installer failed: #{concurrent_stderr.lines.last(8).join}" unless
    concurrent_status.success?
  failures << "launcher observed a partial concurrent activation" unless
    observed.any? && observed.all? { |output, _error, ok| ok && output.include?(fixture.sha) }
end

with_fixture(interpreter) do |fixture|
  _stdout, stderr, status = fixture.run
  failures << "power-loss fixture bootstrap failed: #{stderr.lines.last(8).join}" unless status.success?
  next unless status.success?
  paths = fixture.managed_paths
  stable_links = %i[launcher config notifier].to_h do |name|
    entry = File.lstat(paths.fetch(name))
    [name, [entry.dev, entry.ino, File.readlink(paths.fetch(name))]]
  end
  %w[after_build_launcher after_build_poller after_build_config after_build_notifier
     after_generation_rename before_current after_current].each do |boundary|
    prior_current = File.readlink(paths.fetch(:current))
    candidate = File.join(fixture.root, "power-candidate-#{boundary}.py")
    File.write(
      candidate,
      File.binread(POLLER_SOURCE) + "\n# power boundary #{boundary}\n",
      mode: "wb",
      perm: 0o600
    )
    marker = File.join(fixture.root, "power-marker-#{boundary}")
    reached, power_stdout, power_stderr, power_status = fixture.kill_at_power_boundary(
      {
        "production_auto_deploy_test_poller_source" => candidate,
        "production_auto_deploy_test_power_boundary" => boundary,
        "production_auto_deploy_test_power_marker" => marker
      },
      marker
    )
    failures << "#{boundary} power-loss hook was not reached: #{(power_stdout + power_stderr).lines.last(12).join}" unless reached
    failures << "#{boundary} installer was not actually SIGKILLed" unless
      reached && power_status.signaled? && power_status.termsig == Signal.list.fetch("KILL")
    File.unlink(marker) if File.exist?(marker)
    expected_switched = boundary == "after_current"
    failures << "#{boundary} exposed the wrong atomic current side" unless
      (File.readlink(paths.fetch(:current)) != prior_current) == expected_switched
    status_stdout, status_stderr, status_status = Open3.capture3(
      { "PATH" => "/hostile", "HOME" => "/hostile" },
      paths.fetch(:launcher),
      "--status"
    )
    failures << "#{boundary} power loss left no complete runtime: #{status_stderr}" unless
      status_status.success? && status_stdout.include?(fixture.sha)
    converge_stdout, converge_stderr, converge_status = fixture.run({
      "production_auto_deploy_test_poller_source" => candidate
    })
    failures << "#{boundary} recovery did not converge: #{converge_stderr.lines.last(12).join}" unless
      converge_status.success?
    failures << "#{boundary} recovery did not activate the complete candidate" if
      File.readlink(paths.fetch(:current)) == prior_current
    stable_links.each do |name, identity|
      entry = File.lstat(paths.fetch(name))
      actual = [entry.dev, entry.ino, File.readlink(paths.fetch(name))]
      failures << "#{boundary} replaced stable #{name} symlink" unless actual == identity
    end
    failures << "#{boundary} recovery leaked abandoned role staging" unless
      Dir.glob(File.join(fixture.root, ".local", "share", "nas-platform", ".poller-stage-*")).empty?
    failures << "#{boundary} recovery leaked abandoned generation staging" unless
      Dir.glob(File.join(paths.fetch(:generations), ".generation-*")).empty?
    failures << "#{boundary} recovery leaked the power hook marker" if
      (converge_stdout + converge_stderr).include?(boundary)
  end
end

with_fixture(interpreter) do |fixture|
  _stdout, stderr, status = fixture.run
  failures << "launcher-syntax fixture bootstrap failed: #{stderr.lines.last(8).join}" unless status.success?
  next unless status.success?

  paths = fixture.managed_paths
  prior_current = File.readlink(paths.fetch(:current))
  prior_crontab = File.binread(fixture.crontab)
  prior_generations = Dir.children(paths.fetch(:generations)).sort
  prior_public_links = %i[launcher config notifier].to_h do |name|
    entry = File.lstat(paths.fetch(name))
    [name, [entry.dev, entry.ino, File.readlink(paths.fetch(name))]]
  end
  _syntax_stdout, _syntax_stderr, syntax_status = fixture.run({
    "production_auto_deploy_test_fail_activation" => "candidate_syntax"
  })
  failures << "injected staged launcher syntax failure succeeded" if syntax_status.success?
  failures << "staged launcher syntax failure switched current" unless
    File.readlink(paths.fetch(:current)) == prior_current
  failures << "staged launcher syntax failure mutated the crontab" unless
    File.binread(fixture.crontab) == prior_crontab
  failures << "staged launcher syntax failure published a generation" unless
    Dir.children(paths.fetch(:generations)).sort == prior_generations
  prior_public_links.each do |name, identity|
    entry = File.lstat(paths.fetch(name))
    actual = [entry.dev, entry.ino, File.readlink(paths.fetch(name))]
    failures << "staged launcher syntax failure replaced public #{name}" unless actual == identity
  end
end

with_fixture(interpreter) do |fixture|
  _stdout, stderr, status = fixture.run
  failures << "upgrade fixture bootstrap failed: #{stderr.lines.last(8).join}" unless status.success?
  next unless status.success?

  {
    "structurally distinct reviewed launcher" => { launcher: true },
    "nonsecret config" => { config: true },
    "notifier" => { notifier: true },
    "all stable assets" => { launcher: true, config: true, notifier: true }
  }.each do |label, variants|
    candidate_launcher = File.binread(fixture.managed_paths.fetch(:launcher))
    fixture.rewrite_active_generation(**variants)
    prior_launcher = File.binread(fixture.managed_paths.fetch(:launcher))
    if variants[:launcher]
      failures << "reviewed prior launcher was not structurally distinct" if
        prior_launcher.start_with?(candidate_launcher)
    end
    prior = File.readlink(fixture.managed_paths.fetch(:current))
    stdout, upgrade_stderr, upgrade_status = fixture.run
    failures << "#{label} upgrade failed: #{(stdout + upgrade_stderr).lines.last(12).join}" unless
      upgrade_status.success?
    failures << "#{label} upgrade did not atomically switch generations" if
      upgrade_status.success? && File.readlink(fixture.managed_paths.fetch(:current)) == prior
    failures << "#{label} upgrade leaked the notifier token" if
      (stdout + upgrade_stderr).include?(TOKEN) ||
      File.read(fixture.managed_paths.fetch(:config)).include?(TOKEN)
  end

  token_stdout, token_stderr, token_status = fixture.run({
    "vault_ntfy_dozzle_token" => ROTATED_TOKEN
  })
  failures << "candidate notifier-token upgrade failed: #{token_stderr.lines.last(8).join}" unless
    token_status.success?
  failures << "candidate notifier token leaked" if
    (token_stdout + token_stderr).include?(ROTATED_TOKEN) ||
    File.read(fixture.managed_paths.fetch(:config)).include?(ROTATED_TOKEN)
  second_stdout, second_stderr, second_status = fixture.run({
    "vault_ntfy_dozzle_token" => ROTATED_TOKEN
  })
  failures << "upgraded installation was not idempotent: #{second_stderr.lines.last(8).join}" unless
    second_status.success? &&
    (second_stdout + second_stderr).match?(/changed=0\s+unreachable=0\s+failed=0/)
end

with_fixture(interpreter) do |fixture|
  _stdout, stderr, status = fixture.run
  failures << "launcher-contract fixture bootstrap failed: #{stderr.lines.last(8).join}" unless status.success?
  next unless status.success?
  fixture.rewrite_active_generation(hostile_launcher: true)
  before = snapshot(fixture.root)
  contract_stdout, contract_stderr, contract_status = fixture.run
  failures << "unreachable launcher exec block passed the trusted contract" if contract_status.success?
  failures << "unreachable launcher diagnostic omitted the trusted contract" unless
    (contract_stdout + contract_stderr).include?("trusted contract")
  failures << "unreachable launcher rejection mutated the root" unless snapshot(fixture.root) == before
end

with_fixture(interpreter) do |fixture|
  results = 2.times.map do
    Thread.new { fixture.run }
  end.map(&:value)
  failures << "serialized concurrent installers did not both converge" unless
    results.all? { |_stdout, _stderr, status| status.success? }
  paths = fixture.managed_paths
  failures << "concurrent installers did not publish one valid current pointer" unless
    File.symlink?(paths.fetch(:current)) && File.file?(paths.fetch(:poller))
  if File.file?(fixture.crontab)
    cron = File.read(fixture.crontab)
    failures << "concurrent installers produced duplicate cron entries" unless
      cron.scan("#Ansible: NAS platform production auto-deploy").length == 1 &&
      cron.lines.grep(/nas-platform-deploy/).length == 1
  else
    failures << "concurrent installers did not create the polling cron"
  end
end

with_fixture(interpreter) do |fixture|
  _stdout, stderr, status = fixture.run
  failures << "inherited-lock fixture bootstrap failed: #{stderr.lines.last(8).join}" unless status.success?
  next unless status.success?
  token = "a" * 64
  proof = File.join(
    File.dirname(fixture.managed_paths.fetch(:state)),
    ".production-auto-deploy-lock-proof-#{'b' * 64}.json"
  )
  File.write(
    proof,
    JSON.generate({
      "production_auto_deploy_lock_proof" => token,
      "production_auto_deploy_lock_pid" => Process.pid,
      "production_auto_deploy_lock_proof_path" => proof
    }),
    mode: "w",
    perm: 0o600
  )
  File.chmod(0o600, proof)
  lock_paths = [
    fixture.root,
    fixture.managed_paths.fetch(:state),
    File.join(fixture.managed_paths.fetch(:state), "deployment.lock")
  ]
  locks = lock_paths.map { |path| File.open(path, File::RDONLY) }
  prior_current = File.readlink(fixture.managed_paths.fetch(:current))
  candidate = File.join(fixture.root, "inherited-lock-candidate.py")
  File.write(candidate, File.binread(POLLER_SOURCE) + "\n# inherited lock candidate\n",
             mode: "wb", perm: 0o600)
  begin
    locks.each do |lock|
      raise "could not acquire inherited-lock fixture" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
    end
    proof_stdout, proof_stderr, proof_status = fixture.run({
      "production_auto_deploy_lock_proof" => token,
      "production_auto_deploy_lock_pid" => Process.pid,
      "production_auto_deploy_lock_proof_path" => proof,
      "production_auto_deploy_test_poller_source" => candidate
    })
    failures << "automatic inherited-lock installer deadlocked or failed: #{(proof_stdout + proof_stderr).lines.last(16).join}" unless
      proof_status.success?
    failures << "automatic inherited-lock proof leaked" if (proof_stdout + proof_stderr).include?(token)
    failures << "automatic inherited-lock installer returned busy instead of activating" if
      (proof_stdout + proof_stderr).include?("busy")
    failures << "automatic inherited-lock installer did not switch the candidate" if
      File.readlink(fixture.managed_paths.fetch(:current)) == prior_current
  ensure
    locks.reverse_each do |lock|
      lock.flock(File::LOCK_UN)
      lock.close
    end
    File.unlink(proof) if File.exist?(proof)
  end
end

with_fixture(interpreter) do |fixture|
  _stdout, stderr, status = fixture.run
  failures << "poll contention fixture bootstrap failed: #{stderr.lines.last(8).join}" unless status.success?
  next unless status.success?
  entered = File.join(fixture.root, "poll-entered")
  release = File.join(fixture.root, "poll-release")
  poll = nil
  begin
    poll = start_test_poll(
      fixture,
      interpreter,
      entered: entered,
      release: release
    )
    poll.close_stdin
    deadline = Time.now + 5
    sleep 0.02 until File.exist?(entered) || Time.now >= deadline
    if File.exist?(entered)
      before = snapshot(fixture.root)
      install_stdout, install_stderr, install_status = fixture.run
      failures << "installer did not report a clean busy poll lock" unless
        install_status.success? && (install_stdout + install_stderr).include?("busy")
      failures << "busy installer mutated managed state" unless snapshot(fixture.root) == before
    end
    File.write(release, "release\n", mode: "w", perm: 0o600)
    _poll_stdout, poll_stderr, poll_status = poll.result(
      timeout: 5,
      timeout_diagnostic: POLL_CHILD_TIMEOUT_DIAGNOSTIC
    )
    failures << "real poll did not enter its paused attempt: #{poll_stderr}" unless
      File.exist?(entered)
    failures << "paused poll did not exit cleanly: #{poll_stderr}" unless
      poll_status.success?
  ensure
    poll&.close
  end
end

with_fixture(interpreter) do |fixture|
  _stdout, stderr, status = fixture.run
  failures << "installer contention fixture bootstrap failed: #{stderr.lines.last(8).join}" unless status.success?
  next unless status.success?
  marker = File.join(fixture.root, "installer-lock-held")
  result = nil
  installer = Thread.new do
    result = fixture.run({
      "production_auto_deploy_test_lock_delay" => 1.5,
      "production_auto_deploy_test_lock_marker" => marker
    })
  end
  deadline = Time.now + 15
  sleep 0.02 until File.exist?(marker) || !installer.alive? || Time.now >= deadline
  if File.exist?(marker)
    attempted = File.join(fixture.root, "poll-attempted")
    poll = nil
    begin
      poll = start_test_poll(
        fixture,
        interpreter,
        entered: attempted,
        attempted: attempted
      )
      poll.close_stdin
      _poll_stdout, poll_stderr, poll_status = poll.result(
        timeout: 5,
        timeout_diagnostic: POLL_CHILD_TIMEOUT_DIAGNOSTIC
      )
      failures << "poll did not exit cleanly while installer held the shared lock: #{poll_stderr}" unless
        poll_status.success?
      failures << "poll attempted deployment while installer held the shared lock" if
        File.exist?(attempted)
    ensure
      poll&.close
    end
  else
    failures << "installer never exposed its test-only shared-lock marker"
  end
  installer.join
  _install_stdout, install_stderr, install_status = result
  failures << "shared-lock installer failed: #{install_stderr.lines.last(8).join}" unless install_status.success?
end

with_fixture(interpreter) do |fixture|
  File.write(fixture.crontab, <<~CRON, mode: "w", perm: 0o600)
    #Ansible: NAS platform production auto-deploy
    */5 * * * * /first --poll
    #Ansible: NAS platform production auto-deploy
    */5 * * * * /second --poll
  CRON
  before = snapshot(fixture.root)
  _stdout, stderr, status = fixture.run
  failures << "duplicate managed cron entries were accepted" if status.success?
  failures << "duplicate cron failure omitted diagnostic" unless (_stdout + stderr).include?("duplicate managed cron")
  failures << "duplicate cron failure mutated the root" unless snapshot(fixture.root) == before
end

with_fixture(interpreter) do |fixture|
  launcher = fixture.managed_paths.fetch(:launcher)
  File.write(
    fixture.crontab,
    "*/5 * * * * #{launcher} --poll\n",
    mode: "w",
    perm: 0o600
  )
  before = snapshot(fixture.root)
  _stdout, _stderr, status = fixture.run
  failures << "unmarked exact duplicate cron entry was accepted" if status.success?
  failures << "unmarked duplicate cron failure mutated the root" unless snapshot(fixture.root) == before
end

with_fixture(interpreter) do |fixture|
  paths = fixture.managed_paths
  hostile_lines = [
    "17 2 * * * FOO=1 #{paths.fetch(:launcher)} --poll >>#{fixture.root}/poll.log 2>&1",
    "3 1 * * * >#{fixture.root}/poll.log #{paths.fetch(:launcher)} --status",
    "@reboot #{paths.fetch(:launcher)} --status",
    "0 * * * * #{paths.fetch(:current)}/production_auto_deploy.py --config #{paths.fetch(:config)} --poll",
    "  9\t* * * *\tENV=value\t#{paths.fetch(:launcher)}\t--poll 2>/dev/null",
    "0 * * * * exec #{paths.fetch(:launcher)} --poll",
    "0 * * * * /bin/sh -c '#{paths.fetch(:launcher)} --poll'",
    "0 * * * * cd /tmp && #{paths.fetch(:launcher)} --poll",
    "0 * * * * nice #{paths.fetch(:launcher)} --poll"
  ]
  hostile_lines.each do |line|
    File.write(fixture.crontab, "#{line}\n", mode: "w", perm: 0o600)
    before = snapshot(fixture.root)
    _stdout, _stderr, status = fixture.run
    failures << "unmarked launcher cron syntax was accepted: #{line}" if status.success?
    failures << "hostile cron syntax mutated the root: #{line}" unless snapshot(fixture.root) == before
  end
end

with_fixture(interpreter) do |fixture|
  launcher = fixture.managed_paths.fetch(:launcher)
  File.write(
    fixture.crontab,
    "# 0 * * * * #{launcher} --poll\n0 * * * * #{launcher}-other --poll\n",
    mode: "w",
    perm: 0o600
  )
  _stdout, stderr, status = fixture.run
  failures << "cron parser false-matched comments or a different executable: #{stderr.lines.last(8).join}" unless
    status.success?
end

with_fixture(interpreter) do |fixture|
  password = File.join(fixture.protected, "vault-password")
  File.chmod(0o644, password)
  before = snapshot(fixture.root)
  _stdout, stderr, status = fixture.run
  failures << "world-readable password input was accepted" if status.success?
  failures << "password mode failure omitted diagnostic" unless (_stdout + stderr).include?("0600")
  failures << "password mode failure mutated the root" unless snapshot(fixture.root) == before
end

with_fixture(interpreter) do |fixture|
  controller_python = File.join(fixture.root, "controller-python")
  File.write(
    controller_python,
    "#!/bin/sh\nif [ \"${1-}\" = \"-c\" ]; then echo 3.11; exit 0; fi\nexit 1\n",
    mode: "w",
    perm: 0o700
  )
  File.chmod(0o700, controller_python)
  before = snapshot(fixture.root)
  _stdout, _stderr, status = fixture.run({
    "production_auto_deploy_controller_python" => controller_python
  })
  failures << "controller Python below 3.12 was accepted" if status.success?
  failures << "old controller Python failure mutated the root" unless snapshot(fixture.root) == before

  File.chmod(0o777, controller_python)
  before = snapshot(fixture.root)
  _stdout, _stderr, status = fixture.run({
    "production_auto_deploy_controller_python" => controller_python
  })
  failures << "writable controller Python was accepted" if status.success?
  failures << "writable controller Python failure mutated the root" unless snapshot(fixture.root) == before
end

with_fixture(interpreter) do |fixture|
  vault = File.join(fixture.protected, "vault.yml")
  target = File.join(fixture.protected, "vault-target")
  File.rename(vault, target)
  File.symlink(target, vault)
  before = snapshot(fixture.root)
  _stdout, stderr, status = fixture.run
  failures << "symlinked vault input was accepted" if status.success?
  failures << "vault symlink failure omitted diagnostic" unless (_stdout + stderr).include?("non-symlink")
  failures << "vault symlink failure mutated the root" unless snapshot(fixture.root) == before
end

%i[gitmodules gitlink symlink_tree replace grafts shallow commondir core_worktree fsmonitor wrong_remote dirty].each do |kind|
  with_fixture(interpreter) do |fixture|
    fixture.make_controller_hostile(kind)
    _stdout, _stderr, status = fixture.run
    failures << "hostile real controller repository was accepted: #{kind}" if status.success?
    failures << "cron was created before hostile controller rejection: #{kind}" if
      File.exist?(fixture.crontab)
    failures << "hostile core.fsmonitor executed before rejection" if
      kind == :fsmonitor && File.exist?(fixture.fsmonitor_marker)
  end
end

with_fixture(interpreter) do |fixture|
  before = snapshot(fixture.root)
  _stdout, stderr, status = fixture.run({
    "production_auto_deploy_test_identity" => {
      "uid" => Process.euid, "gid" => Process.egid, "user" => "root", "home" => Dir.home
    }
  })
  failures << "wrong-owner protected inputs were accepted" if status.success?
  failures << "wrong-owner failure omitted diagnostic" unless (_stdout + stderr).include?("owned by the effective account")
  failures << "wrong-owner failure mutated the root" unless snapshot(fixture.root) == before
end

suite_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - suite_started_at
failures << ROLE_SUITE_TIMEOUT_DIAGNOSTIC if suite_elapsed > ROLE_SUITE_BUDGET_SECONDS
suite_watchdog.kill
suite_watchdog.join

if failures.empty?
  puts "Production auto-deploy role: all tests passed"
else
  warn failures.map { |failure| "- #{failure}" }.join("\n")
  exit 1
end
