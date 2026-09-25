#!/usr/bin/env bash
# Bu makineyi "ana ajan bilgisayarı" yapar:
#   - Tailscale + Tailscale SSH (anahtar/şifre derdi yok, sadece tailnet cihazları girebilir)
#   - tmux: oturumlar SSH kopsa da yaşar
#   - mosh: telefonda kopmayan bağlantı
#   - Claude Code CLI + açılışta kendiliğinden başlayan "agent" tmux oturumu
#   - Uyku/suspend kapalı (sunucu gibi hep açık)
#
# Kullanım:  bash setup-agent-host.sh
set -euo pipefail

SESSION=agent
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
AS_USER=(sudo -u "$TARGET_USER" -H)

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

log "Paketler kuruluyor (tmux, mosh, git, curl)"
if command -v apt-get >/dev/null; then
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y tmux mosh git curl ca-certificates
elif command -v dnf >/dev/null; then
  dnf install -y tmux mosh git curl
elif command -v pacman >/dev/null; then
  pacman -Sy --noconfirm tmux mosh git curl
else
  echo "Desteklenmeyen paket yöneticisi; tmux mosh git curl'ü elle kur." >&2
fi

log "Tailscale kuruluyor"
if ! command -v tailscale >/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable --now tailscaled

log "Tailscale'e bağlanılıyor (Tailscale SSH açık)"
# Zaten bağlıysa sadece SSH'ı açar; değilse bir giriş linki basar, onu telefonda aç.
tailscale up --ssh --hostname="${AGENT_HOSTNAME:-agent}" || tailscale set --ssh

log "Uyku/suspend kapatılıyor"
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1 || true
if [ -f /etc/systemd/logind.conf ]; then
  sed -i 's/^#\?HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
  grep -q '^HandleLidSwitch=' /etc/systemd/logind.conf || echo 'HandleLidSwitch=ignore' >> /etc/systemd/logind.conf
fi

log "Claude Code kuruluyor ($TARGET_USER için)"
if ! "${AS_USER[@]}" bash -lc 'command -v claude' >/dev/null 2>&1; then
  "${AS_USER[@]}" bash -lc 'curl -fsSL https://claude.ai/install.sh | bash'
fi

log "'agent' komutu kuruluyor"
cat > /usr/local/bin/agent <<EOF
#!/usr/bin/env bash
# Ajan tmux oturumuna bağlan (yoksa oluştur). Çıkmak için: Ctrl-b d
export PATH="\$HOME/.local/bin:\$PATH"
tmux has-session -t $SESSION 2>/dev/null || tmux new-session -d -s $SESSION -c "\$HOME"
exec tmux attach -t $SESSION
EOF
chmod +x /usr/local/bin/agent

log "tmux ayarları"
if [ ! -f "$TARGET_HOME/.tmux.conf" ]; then
  cat > "$TARGET_HOME/.tmux.conf" <<'EOF'
set -g mouse on
set -g history-limit 100000
set -g default-terminal "tmux-256color"
set -g status-right "#H  %H:%M"
EOF
  chown "$TARGET_USER": "$TARGET_HOME/.tmux.conf"
fi

log "Açılışta 'agent' tmux oturumu başlatan servis"
cat > /etc/systemd/system/agent-tmux@.service <<EOF
[Unit]
Description=Kalıcı ajan tmux oturumu (%i)
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=forking
User=%i
Environment=PATH=$TARGET_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
WorkingDirectory=~
ExecStart=/usr/bin/tmux new-session -d -s $SESSION
ExecStop=/usr/bin/tmux kill-session -t $SESSION
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now "agent-tmux@$TARGET_USER.service" || true

TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
TS_NAME="$(tailscale status --json 2>/dev/null | grep -m1 '"DNSName"' | cut -d'"' -f4 | sed 's/\.$//' || true)"

cat <<EOF

================================================================
 KURULUM TAMAM
================================================================
 Tailscale adresi : ${TS_IP:-?}   (${TS_NAME:-agent})

 Diğer bilgisayardan (Tailscale açık):
     ssh $TARGET_USER@${TS_NAME:-agent}     ->  sonra:  agent

 Telefondan (Termius):
     Host: ${TS_IP:-<tailscale-ip>}   Kullanıcı: $TARGET_USER
     Telefonda Tailscale uygulaması açık olmalı.
     Bağlanınca:  agent

 SON ADIM (bir kez, elle):
     agent            # tmux'a gir
     claude           # ilk açılışta tarayıcıdan giriş yap (/login)
     claude remote-control
       -> Artık bu oturumu telefondaki Claude uygulamasından da
          (Claude Code bölümü) yönetebilirsin.

 tmux'tan çıkmak (oturum çalışmaya devam eder): Ctrl-b sonra d
================================================================
EOF
