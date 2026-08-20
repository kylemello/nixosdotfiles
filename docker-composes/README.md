# docker-composes

Compose definitions for the local dev stacks, managed by Nix
(`home/docker-composes.nix` links this tree to `~/docker-composes`) and started
by hand:

```
cd ~/docker-composes/<stack> && docker compose up -d
```

Nix manages the definitions ONLY. Nothing here is a systemd unit, nothing starts
at boot, and no `.env` is committed — see the module for why.
