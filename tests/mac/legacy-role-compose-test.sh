#!/bin/sh
set -eu
set +x
umask 077

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$test_dir/../.." && pwd -P)
manifest=$repo_dir/services/manifest.yml

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

ansible_playbook=$(command -v ansible-playbook 2>/dev/null || true)
ansible_vault=$(command -v ansible-vault 2>/dev/null || true)
[ -x "$ansible_playbook" ] && [ -x "$ansible_vault" ] ||
  fail 'pinned Ansible is required for legacy role Compose compatibility tests'
case $("$ansible_playbook" --version 2>/dev/null | sed -n '1p') in
  'ansible-playbook [core 2.21.2]') ;;
  *) fail 'ansible-core 2.21.2 is required for legacy role Compose compatibility tests' ;;
esac
command -v docker >/dev/null 2>&1 ||
  fail 'Docker Compose is required for legacy role Compose compatibility tests'

legacy_root=${NAS_INFRASTRUCTURE_DIR:-$repo_dir/../nas-infrastructure}
legacy_root=$(CDPATH= cd -- "$legacy_root" 2>/dev/null && pwd -P) ||
  fail 'the pinned legacy checkout is required for compatibility tests'
legacy_commit=$(ruby -ryaml -e 'print YAML.safe_load_file(ARGV.fetch(0)).fetch("legacy_source").fetch("commit")' "$manifest")
git -C "$legacy_root" cat-file -e "$legacy_commit^{commit}" 2>/dev/null ||
  fail 'the exact pinned legacy commit is unavailable'

temporary_input=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-legacy-role-compose.XXXXXX")
temporary_root=$(CDPATH= cd -- "$temporary_input" && pwd -P)
cleanup() {
  test_status=$?
  trap - EXIT HUP INT TERM
  if [ -d "$temporary_root" ] && [ ! -L "$temporary_root" ]; then
    /usr/bin/find "$temporary_root" -depth -delete
  fi
  exit "$test_status"
}
trap cleanup EXIT HUP INT TERM

for role_tag in ntfy beszel dozzle audiobookshelf komga jellyfin immich paperless tinymediamanager; do
  task_list=$temporary_root/$role_tag.tasks
  ANSIBLE_NOCOLOR=1 "$ansible_playbook" -i "$repo_dir/inventory/mac.yml" \
    "$test_dir/legacy-role-seed.yml" --tags "$role_tag" --list-tasks > "$task_list" 2>&1 ||
    fail 'a supported legacy role seed entrypoint is invalid'
  [ -s "$task_list" ] || fail 'a supported legacy role seed entrypoint is empty'
done

vault_password=$temporary_root/password
vault_plain=$temporary_root/vault.yml
vault_file=$temporary_root/vault.enc
printf '%s\n' disposable-vault-password > "$vault_password"
cat > "$vault_plain" <<'YAML'
vault_test_ntfy_users: 'admin:$2y$05$disposablehash,user:$2y$05$disposablehash'
vault_test_ntfy_access: 'admin:*:rw,user:nas-critical:w'
vault_test_ntfy_tokens: 'user:tk_disposable-token'
vault_tinymediamanager_password: 'disposable-tmm-password'
vault_beszel_agent_key: 'ssh-ed25519-disposable-public-key'
vault_beszel_universal_token: 'disposable-beszel-token'
vault_paperless_db_name: 'paperless'
vault_paperless_db_username: 'paperless'
vault_paperless_db_password: 'disposable-paperless-db-password'
vault_paperless_django_secret_key: 'disposable-paperless-secret-key'
vault_paperless_admin_username: 'administrator'
vault_paperless_admin_password: 'disposable-paperless-admin-password'
vault_paperless_admin_email: 'administrator@example.invalid'
YAML
chmod 0600 "$vault_password" "$vault_plain"
"$ansible_vault" encrypt --vault-password-file "$vault_password" \
  --output "$vault_file" "$vault_plain" >/dev/null 2>&1 ||
  fail 'could not create the disposable encrypted deployment vault'
rm -f -- "$vault_plain"

render_root=$temporary_root/rendered
mkdir -m 0700 "$render_root"
playbook=$temporary_root/render.yml
cat > "$playbook" <<YAML
---
- name: Render production role environments from a disposable deployment vault
  hosts: localhost
  gather_facts: false
  vars_files:
    - "$vault_file"
  vars:
    nas_timezone: UTC
    nas_uid: 501
    nas_gid: 20
    nas_docker_root: /disposable/docker
    nas_media_root: /disposable/media
    ntfy_base_url: http://127.0.0.1:32586
    ntfy_port: 32586
    platform_project_name: disposable-adoption
    platform_render_device_path: ''
    beszel_app_url: http://127.0.0.1:38090
    beszel_port: 38090
    beszel_system_name: disposable-legacy
    ntfy_auth_users: "{{ vault_test_ntfy_users }}"
    ntfy_auth_access: "{{ vault_test_ntfy_access }}"
    ntfy_auth_tokens: "{{ vault_test_ntfy_tokens }}"
    tinymediamanager_web_port: 34000
    tinymediamanager_api_port: 37878
    platform_compose_kind: mac
    paperless_task_workers: 1
    paperless_threads_per_worker: 1
    paperless_port: 38000
    paperless_ai_enabled: false
    paperless_ai_llm_endpoint: http://example.invalid:11434
    paperless_ai_llm_model: disposable
  tasks:
    - name: Render the production ntfy role environment
      ansible.builtin.template:
        src: "$repo_dir/roles/ntfy/templates/env.j2"
        dest: "$render_root/ntfy.env"
        mode: "0600"
      no_log: true
    - name: Render the production tinyMediaManager role environment
      ansible.builtin.template:
        src: "$repo_dir/roles/tinymediamanager/templates/env.j2"
        dest: "$render_root/tinymediamanager.env"
        mode: "0600"
      no_log: true
    - name: Render the production Beszel role environment
      ansible.builtin.template:
        src: "$repo_dir/roles/beszel/templates/env.j2"
        dest: "$render_root/beszel.env"
        mode: "0600"
      no_log: true
    - name: Render the production Paperless role environment
      ansible.builtin.template:
        src: "$repo_dir/roles/paperless_ngx/templates/env.j2"
        dest: "$render_root/paperless-ngx.env"
        mode: "0600"
      no_log: true
YAML
ANSIBLE_NOCOLOR=1 "$ansible_playbook" -i localhost, -c local "$playbook" \
  --vault-password-file "$vault_password" >/dev/null 2>&1 ||
  fail 'production role environment rendering failed'

base_for() {
  service=$1
  legacy_path=$(ruby -ryaml - "$manifest" "$service" <<'RUBY'
manifest, requested = ARGV
entry = YAML.safe_load_file(manifest, aliases: false).fetch("services").find do |candidate|
  candidate.fetch("name") == requested
end
abort unless entry
print entry.fetch("legacy_path")
RUBY
  ) || fail 'legacy manifest lookup failed'
  git -C "$legacy_root" show "$legacy_commit:$legacy_path" > "$temporary_root/$service.base.yml" 2>/dev/null ||
    fail 'could not materialize an exact pinned legacy Compose file'
  printf '%s\n' "$temporary_root/$service.base.yml"
}

validate_config() {
  service=$1
  override=$2
  env_file=${3:-$render_root/$service.env}
  base=$(base_for "$service")
  output=$temporary_root/$service.config.json
  diagnostic=$temporary_root/$service.config.error
  if ! PLATFORM_MAC_SANDBOX="$temporary_root/sandbox" docker compose \
      --project-name "disposable-$service" --env-file "$env_file" \
      -f "$base" -f "$override" config --format json > "$output" 2> "$diagnostic"; then
    return 1
  fi
  ruby -rjson - "$service" "$env_file" "$output" >/dev/null 2>&1 <<'RUBY'
service, environment_path, config_path = ARGV
environment = File.readlines(environment_path, chomp: true).reject do |line|
  line.empty? || line.start_with?("#")
end.to_h do |line|
  key, value = line.split("=", 2)
  [key, value]
end
services = JSON.parse(File.read(config_path)).fetch("services")
if service == "ntfy"
  config = services.fetch("ntfy")
  container_environment = config.fetch("environment")
  raise unless config.fetch("user") == "#{environment.fetch('NAS_UID')}:#{environment.fetch('NAS_GID')}"
  %w[NTFY_AUTH_USERS NTFY_AUTH_ACCESS NTFY_AUTH_TOKENS].each do |key|
    expected = environment.fetch(key)
    raise if expected.empty? || container_environment.fetch(key) != expected
  end
elsif service == "tinymediamanager"
  container_environment = services.fetch("tinymediamanager").fetch("environment")
  expected = environment.fetch("TINYMEDIAMANAGER_PASSWORD")
  raise if expected.empty? || container_environment.fetch("PASSWORD") != expected
  raise unless environment.fetch("PASSWORD") == expected
elsif service == "beszel"
  agent = services.fetch("agent").fetch("environment")
  raise unless agent.fetch("KEY") == environment.fetch("BESZEL_AGENT_KEY")
  raise unless agent.fetch("TOKEN") == environment.fetch("BESZEL_AGENT_TOKEN")
elsif service == "paperless-ngx"
  database = services.fetch("db").fetch("environment")
  webserver = services.fetch("webserver").fetch("environment")
  raise unless database.fetch("POSTGRES_PASSWORD") == environment.fetch("DB_PASSWORD")
  raise unless webserver.fetch("PAPERLESS_DBPASS") == environment.fetch("DB_PASSWORD")
  raise unless webserver.fetch("PAPERLESS_SECRET_KEY") == environment.fetch("PAPERLESS_SECRET_KEY")
else
  raise
end
RUBY
}

ntfy_override=$test_dir/legacy-overrides/ntfy.yml
tmm_override=$test_dir/legacy-overrides/tinymediamanager.yml
beszel_override=$test_dir/legacy-overrides/beszel.yml
paperless_override=$test_dir/legacy-overrides/paperless-ngx.yml
adapter_failed=false
if ! validate_config ntfy "$ntfy_override"; then
  printf '%s\n' 'ntfy legacy role adapter is incompatible' >&2
  adapter_failed=true
fi
if ! validate_config tinymediamanager "$tmm_override"; then
  printf '%s\n' 'tinyMediaManager legacy role adapter is incompatible' >&2
  adapter_failed=true
fi
if ! validate_config beszel "$beszel_override"; then
  printf '%s\n' 'Beszel legacy role prerequisites are incompatible' >&2
  adapter_failed=true
fi
if ! validate_config paperless-ngx "$paperless_override"; then
  printf '%s\n' 'Paperless legacy role prerequisites are incompatible' >&2
  adapter_failed=true
fi
[ "$adapter_failed" = false ] || exit 1

ntfy_no_identity=$temporary_root/ntfy-no-identity.yml
sed '/^[[:space:]]*user:/d' "$ntfy_override" > "$ntfy_no_identity"
if validate_config ntfy "$ntfy_no_identity"; then
  fail 'ntfy adapter accepted removal of the role-rendered identity mapping'
fi
ntfy_mismatched_auth=$temporary_root/ntfy-mismatched-auth.yml
sed 's/NTFY_AUTH_TOKENS:.*$/NTFY_AUTH_TOKENS: "${NTFY_AUTH_ACCESS:?}"/' \
  "$ntfy_override" > "$ntfy_mismatched_auth"
if validate_config ntfy "$ntfy_mismatched_auth"; then
  fail 'ntfy adapter accepted a mismatched declarative token mapping'
fi
tmm_no_password=$temporary_root/tinymediamanager-no-password.env
sed '/^PASSWORD=/d' "$render_root/tinymediamanager.env" > "$tmm_no_password"
if validate_config tinymediamanager "$tmm_override" "$tmm_no_password"; then
  fail 'tinyMediaManager adapter accepted removal of the role-rendered password mapping'
fi
tmm_mismatched_password=$temporary_root/tinymediamanager-mismatched-password.env
sed 's/^PASSWORD=.*$/PASSWORD=mismatched-disposable-password/' \
  "$render_root/tinymediamanager.env" > "$tmm_mismatched_password"
if validate_config tinymediamanager "$tmm_override" "$tmm_mismatched_password"; then
  fail 'tinyMediaManager adapter accepted a mismatched role-rendered password mapping'
fi
beszel_no_token=$temporary_root/beszel-no-token.env
sed '/^BESZEL_AGENT_TOKEN=/d' "$render_root/beszel.env" > "$beszel_no_token"
if validate_config beszel "$beszel_override" "$beszel_no_token"; then
  fail 'Beszel prerequisites accepted a missing rendered role environment token'
fi
paperless_no_database_password=$temporary_root/paperless-no-database-password.env
sed '/^DB_PASSWORD=/d' "$render_root/paperless-ngx.env" > "$paperless_no_database_password"
if validate_config paperless-ngx "$paperless_override" "$paperless_no_database_password"; then
  fail 'Paperless prerequisites accepted a missing rendered role database password'
fi

if grep -R -F 'disposable-tmm-password' "$temporary_root" \
    --exclude='*.env' --exclude='*.enc' --exclude='*.json' --exclude='render.yml' >/dev/null 2>&1; then
  fail 'a compatibility diagnostic exposed a protected value'
fi
printf '%s\n' 'Legacy role Compose compatibility: production role environments fit pinned stacks'
