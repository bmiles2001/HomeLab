# Editing from your main PC

The goal: the work happens here, the action happens there. No Google Remote
Desktop, no UNC share, no editing YAML through a screen-sharing session.

Two layers, and you want both.

## Layer 1 — SSH, for interactive work

Nothing to install. Ubuntu's OpenSSH server was set up during installation, and
importing your GitHub identity put your main PC's public key into
`~/.ssh/authorized_keys` already. See
[forge-session-runbook.md](forge-session-runbook.md) phase 0.

Add a host alias on your main PC (`~/.ssh/config`):

```
Host forge
    HostName 10.0.0.4
    User netto
```

`ssh forge` lands you on the server. That is the whole thing — there is no
second hop, no `RemoteCommand`, and no Windows shell to escape from. This is
what the pivot to Linux bought.

### VS Code Remote-SSH

Install the Remote-SSH extension on your main PC, connect to `forge`, open
`~/home-containers`. Files edit as though local, the integrated terminal runs
`docker` on the far side, and `git` works from either end.

This is the RDP replacement. It's also the only comfortable way to read logs.

## Layer 2 — Git, for the record

SSH is for looking. Git is for changing.

```
main PC:  edit -> commit -> push
host:     git pull -> ./scripts/deploy.sh <stack>
```

On the host, `~/home-containers` is a clone with a read-only deploy key, so a
compromised container can't push. Generate it on forge and add it
under **Settings → Deploy keys** on the GitHub repo:

```bash
ssh-keygen -t ed25519 -C "forge deploy key" -f ~/.ssh/id_deploy
```

### One-command redeploy

```bash
cat >> ~/.bashrc <<'EOF'
redeploy() {
  cd ~/home-containers && git pull --ff-only && ./scripts/deploy.sh "$1"
}
EOF
```

Then `redeploy immich` after any push.

Add a webhook or a polling timer later if you want it automatic. Manual is
fine and arguably better while the repo is young — an unattended pull that
deploys a broken commit at 3am is a worse problem than typing eight
characters.

## Make the repo private

It contains your domain, your internal addressing, and your architecture. None
of that is catastrophic on its own, and none of it needs to be public either.

## The rule, restated

Never edit files on the host. If you fix something there in a hurry, either
port it back to a commit the same evening or accept that the repo is now
fiction. There's no third option — the drift is silent and it compounds.
