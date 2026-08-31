# Mac platform proof manual review

Record the report path, deployment manifest Git commit, reviewer, timestamp,
and a pass/fail decision. Never paste passwords, tokens, authorization headers,
private keys, password hashes, rendered environment files, or application logs.

## Application checks

- [ ] Audiobookshelf: scan, browse, play, and retain progress after recreation.
- [ ] Komga: scan and open a disposable book; retain library settings.
- [ ] Jellyfin: scan, direct-stream, CPU-transcode, and retain users/libraries.
- [ ] Immich: upload, thumbnail, search, exercise CPU ML, and retain assets.
- [ ] Paperless-ngx: ingest German/English/Hebrew fixtures, preview, search,
      convert, export, and inspect Gmail configuration without fetching mail.
- [ ] Pinchflat: sign in with the deployed basic-authentication pair; confirm an
      anonymous request and a wrong password are both refused, and that the
      persisted database survives recreation.
- [ ] Kapowarr: sign in with the deployed administrator identity; confirm an
      anonymous request and a wrong password are both refused, that the owned
      comics library root and persisted database survive recreation, and that
      the ComicVine key is present in the application.
- [ ] Bindery: sign in with the deployed administrator identity; confirm an
      anonymous request to a protected route is refused, that the ebook and
      audiobook library roots and the persisted database survive recreation,
      and that unattended auto-grabbing is still off. Spend exactly one login —
      the limiter answers 429 to the correct password after five failures.
- [ ] Trailarr: sign in with the deployed administrator identity; confirm the
      published default administrator (admin / trailarr) is refused, that an
      anonymous request to a protected route is refused, that monitoring and
      downloads are still off, and that both trailer profiles write an mp4 into
      a Trailers/ subdirectory of the item's own folder. Then change one
      setting in the web interface, reconverge, and confirm it is reverted —
      the application's own /config/.env is what makes that true.
- [ ] Seerr: sign in with the deployed Jellyfin administrator and confirm the
      managed household user can sign in too and can raise a request that is
      approved immediately, with no quota and no service-administration menu.
      Confirm the setup wizard does not appear. Then toggle "Enable New Media
      Server Sign-In" on in the settings, reconverge, and confirm it is off
      again — with it on, a Jellyfin user the platform never declared is
      silently created here.
- [ ] ntfy: confirm anonymous denial and authenticated disposable messages.
- [ ] Beszel: inspect metrics/thresholds and send a disposable ntfy event.
- [ ] Dozzle: inspect logs and event rules; confirm shell/actions/MCP are off.

## NAS-only limitations

- [ ] Confirm the generated report has exactly the four bounded foundation
      lines: `MEDIA_ACQUISITION_FOUNDATION`, `MEDIA_ACQUISITION_STORAGE`,
      `MEDIA_ACQUISITION_TRANSPORTS`, and `MEDIA_ACQUISITION_CONTAINERS`; do not
      attach secrets, logs, or directory listings.
- [ ] Record that drift removed the exact labeled bridge, disconnected only
      Jellyfin and Audiobookshelf, and that reconcile restored the exact state;
      abort-path tests restore state before preserving the failure status.
- [ ] Confirm cleanup leaves zero proof-owned containers and networks while
      preserving unrelated Docker resources.
- [ ] Docker Desktop cannot prove NAS ACL enforcement. On the NAS, ordinary SMB
      users must be denied both `Media/.acquisition` and `Books/.acquisition`.
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
