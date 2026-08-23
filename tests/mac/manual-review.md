# Mac platform proof manual review

Record the report path, deployment manifest Git commit, reviewer, timestamp,
and a pass/fail decision. Never paste passwords, tokens, authorization headers,
private keys, password hashes, rendered environment files, or application logs.

## Application checks

- [ ] Audiobookshelf: scan, browse, play, and retain progress after recreation.
- [ ] Komga: scan and open a disposable book; retain library settings.
- [ ] Jellyfin: scan, direct-stream, CPU-transcode, and retain users/libraries.
- [ ] tinyMediaManager: confirm it is retired, its container is absent, it must
      remain stopped, and its bind-mounted state remains preserved.
- [ ] Retired media manager: perform no active UI, API, or metadata-write
      verification.
- [ ] Immich: upload, thumbnail, search, exercise CPU ML, and retain assets.
- [ ] Paperless-ngx: ingest German/English/Hebrew fixtures, preview, search,
      convert, export, and inspect Gmail configuration without fetching mail.
- [ ] ntfy: confirm anonymous denial and authenticated disposable messages.
- [ ] Beszel: inspect metrics/thresholds and send a disposable ntfy event.
- [ ] Dozzle: inspect logs and event rules; confirm shell/actions/MCP are off.

## NAS-only limitations

- [ ] Intel GPU access and hardware transcoding remain unproved.
- [ ] Linux performance capabilities and Intel GPU metrics remain unproved.
- [ ] ADM Defender, host networking, native NAS mounts, and Tailscale remain unproved.
- [ ] Production-scale data, real Gmail consumption, external Ollama, mobile
      push, and complete NAS outage detection remain unproved.

## Decision

- Reviewer:
- Timestamp:
- Manifest Git commit:
- Automated report:
- Result: pass / fail
- Notes:
