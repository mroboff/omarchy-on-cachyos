#!/usr/bin/env bash
# =============================================================================
# omarchy-qt-color-fix.sh — fix menú 100% negro tras Qt 6.12 (omacom/omarchy#14469)
#
# Causa   : Qt 6.12 añadió el tipo QML `Color` (QQuickColor) en QtQuick, que
#           colisiona con el singleton `Color` de qs.Commons. En archivos que
#           importan QtQuick + qs.Commons, `Color` resuelve al tipo de Qt
#           (sin bar/menu/tooltip/shellValues) → todo undefined → menú negro.
# Fix     : cualificar el singleton: `import qs.Commons as C` + `C.Color.`
#
# USO
#   omarchy-qt-color-fix.sh               aplica el fix (idempotente) si falta
#   omarchy-qt-color-fix.sh --check       solo informa: exit 0 = necesita fix,
#                                         exit 1 = no hace falta; no toca nada
#   omarchy-qt-color-fix.sh --force       aplica aunque Qt < 6.12 (pruebas)
#   omarchy-qt-color-fix.sh --no-restart  no reinicia quickshell al final
#   omarchy-qt-color-fix.sh --uninstall   retira hook + este script del sistema
#
# IDEMPOTENTE: correrlo dos veces es un no-op. El sed solo cualifica un
# `Color.` cuando NO va precedido de `.` ni de un carácter de palabra, así que
# un `C.Color.` ya parcheado NO se vuelve a tocar (nada de `C.C.Color.`).
#
# HOOK DE PACMAN: se instala como /etc/pacman.d/hooks/omarchy-qt-color-fix.hook
# para re-aplicar el fix tras cada upgrade del paquete `omarchy` (que pisa
# /usr/share/omarchy/shell con versiones sin corregir). El apply SIEMPRE sale
# con 0 aunque algo falle, para no abortar la transacción (el fallo se reporta
# y se reintenta a mano).
#
# TRAS EL FIX DE UPSTREAM: cuando omarchy publique un paquete con el singleton
# ya corregido, el detect no encuentra `Color.` sin cualificar → no-op. Para
# retirar de un sistema ya instalado: `omarchy-qt-color-fix.sh --uninstall`.
# En el repo del instalador: borrar este script + el .hook + el flag --fix-qt
# (eliminar el commit) y listo.
# =============================================================================
set -euo pipefail

CHECK=0
FORCE=0
RESTART=1
UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --check)      CHECK=1 ;;
    --force)      FORCE=1 ;;
    --no-restart) RESTART=0 ;;
    --uninstall)  UNINSTALL=1 ;;
    *) echo "argumento desconocido: $arg (usa --check|--force|--no-restart|--uninstall)" >&2; exit 2 ;;
  esac
done

SHELL_DIR="${OMARCHY_FIX_SHELL_DIR:-/usr/share/omarchy/shell}"
HOOK_PATH="/etc/pacman.d/hooks/omarchy-qt-color-fix.hook"
LOG_PFX="omarchy-qt-color-fix"

log()  { echo "[$LOG_PFX] $*"; }

# ---------------------------------------------------------------------------
# Detección
# ---------------------------------------------------------------------------
qt_version() {
  pacman -Q qt6-base 2>/dev/null | awk '{print $2}' | grep -oE '^[0-9]+\.[0-9]+' || true
}

qt_problematic() {
  [ "$FORCE" = "1" ] && return 0
  local ver major minor
  ver=$(qt_version)
  [ -z "$ver" ] && return 1
  major="${ver%%.*}"; minor="${ver#*.}"
  [ "$major" -gt 6 ] && return 0
  [ "$major" -eq 6 ] && [ "$minor" -ge 12 ] && return 0
  return 1
}

# ¿El archivo tiene alguna línea con `Color.` que no sea un acceso ya
# cualificado `C.Color.`?
line_unqualified() {
  awk '/Color\./ && $0 !~ /C\.Color\./ { found=1 } END { exit !found }' "$1"
}

# Lista (una por línea) de archivos .qml del dir con `Color.` sin cualificar.
has_unqualified_color() {
  local dir="$1" f
  [ -d "$dir" ] || return 0
  while IFS= read -r f; do
    if line_unqualified "$f"; then echo "$f"; fi
  done < <(grep -rlE '\bColor\.' "$dir" --include=*.qml 2>/dev/null || true)
}

find_plugin_dirs() {
  {
    ls -d /home/*/.config/omarchy/plugins 2>/dev/null || true
    [ -n "${HOME:-}" ] && [ -d "$HOME/.config/omarchy/plugins" ] && echo "$HOME/.config/omarchy/plugins"
    [ "$(id -u)" = "0" ] && [ -d /root/.config/omarchy/plugins ] && echo "/root/.config/omarchy/plugins"
  } | sort -u
}

# ---------------------------------------------------------------------------
# Aplicación (idempotente, preserva propietario si corre root sobre archivos
# del usuario)
# ---------------------------------------------------------------------------
insert_import() {
  local f="$1" own
  grep -q "import qs.Commons as C" "$f" && return 0
  own="$(stat -c %U:%G "$f" 2>/dev/null || true)"
  awk -v ins="import qs.Commons as C" '
    { lines[NR]=$0; if ($0 ~ /^import /) last=NR }
    END {
      for (i=1;i<=NR;i++) { print lines[i]; if (i==last && last>0) print ins }
      if (last==0) print ins
    }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  [ -n "$own" ] && chown "$own" "$f" 2>/dev/null || true
}

qualify_color() {
  local f="$1" own
  own="$(stat -c %U:%G "$f" 2>/dev/null || true)"
  # Solo cualifica `Color.` que no venga de un acceso ya cualificado
  # (`C.Color.` = va precedido de punto) ni sea subcadena de una palabra
  # (`xColor.`). Idempotente por construcción.
  sed -i -E 's/(^|[^.[:alnum:]_])Color\./\1C.Color./g' "$f"
  [ -n "$own" ] && chown "$own" "$f" 2>/dev/null || true
}

patch_dir() {
  local dir="$1" files=() f backup
  [ -d "$dir" ] || { log "skip: $dir no existe"; return 0; }
  while IFS= read -r f; do files+=("$f"); done < <(has_unqualified_color "$dir")
  [ "${#files[@]}" -eq 0 ] && { log "ok: $dir sin Color. sin cualificar (nada que hacer)"; return 0; }
  backup="$dir.bak-colorfix-$(date +%Y%m%d-%H%M%S)"
  cp -a "$dir" "$backup"
  log "backup: $dir → $backup"
  for f in "${files[@]}"; do
    insert_import "$f"
    qualify_color "$f"
  done
  log "ok: $dir — ${#files[@]} archivos parcheados"
  return 1   # señal: hubo cambios (caché + reinicio en el llamador)
}

restart_shell() {
  [ "$RESTART" = "1" ] || return 0
  if pgrep -x quickshell >/dev/null 2>&1; then
    log "reiniciando quickshell para cargar el fix (el supervisor lo relanza)..."
    pkill -x quickshell 2>/dev/null || true
  fi
}

uninstall() {
  local removed=0
  if [ -f "$HOOK_PATH" ]; then
    rm -f "$HOOK_PATH"; log "hook eliminado: $HOOK_PATH"; removed=1
  fi
  if [ -f "$0" ] && [ "$(basename "$0")" = "omarchy-qt-color-fix.sh" ] \
     && [ "$(dirname "$(readlink -f "$0")")" = "/usr/local/bin" ]; then
    rm -f "$0"; log "script eliminado: $0"; removed=1
  else
    log "este script no está instalado en /usr/local/bin (no se auto-elimina)."
  fi
  [ "$removed" = "0" ] && log "no encontré hook ni script instalados — nada que retirar."
  return 0
}

# ---------------------------------------------------------------------------
# CachyOS migration guards
# ---------------------------------------------------------------------------
guard_cachyos_migrations() {
  local mig_file="/usr/share/omarchy/migrations/1791403310.sh"
  if [ -f "$mig_file" ]; then
    local home ustate uowner
    for home in /home/*; do
      [ -d "$home" ] || continue
      ustate="$home/.local/state/omarchy/migrations"
      if [ ! -f "$ustate/1791403310.sh" ]; then
        mkdir -p "$ustate"
        touch "$ustate/1791403310.sh"
        uowner="$(stat -c '%u:%g' "$home" 2>/dev/null || true)"
        [ -n "$uowner" ] && chown -R "$uowner" "$home/.local/state/omarchy" 2>/dev/null || true
      fi
    done
    if [ -d /etc/skel ]; then
      mkdir -p /etc/skel/.local/state/omarchy/migrations
      touch /etc/skel/.local/state/omarchy/migrations/1791403310.sh
    fi
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  [ "$UNINSTALL" = "1" ] && { uninstall; return 0; }

  guard_cachyos_migrations

  log "Qt6-base detectado: $(qt_version || echo ausente)"
  if ! qt_problematic; then
    log "Qt < 6.12 o sin qt6-base: el bug de colisión no aplica, no se toca nada."
    return 0
  fi

  local shell_needs pdir changed=0
  shell_needs=$(has_unqualified_color "$SHELL_DIR" | wc -l)
  if [ "$CHECK" = "1" ]; then
    if [ "$shell_needs" -gt 0 ]; then
      log "$shell_needs archivos requieren fix en $SHELL_DIR — se necesita aplicar"
      return 0
    fi
    log "shell ya corregido o sin Color. sin cualificar — no hace falta fix"
    return 1
  fi

  log "aplicando parche (Qt 6.12, singleton Color)..."
  if patch_dir "$SHELL_DIR"; then :; else changed=1; fi
  while IFS= read -r pdir; do
    [ -z "$pdir" ] && continue
    if patch_dir "$pdir"; then :; else changed=1; fi
  done < <(find_plugin_dirs)

  if [ "$changed" = "1" ]; then
    log "limpiando caché qmlcache de quickshell (todos los usuarios)..."
    rm -rf /home/*/.cache/quickshell/qmlcache 2>/dev/null || true
    restart_shell
  else
    log "sin cambios: el fix ya estaba aplicado (o no quedaba nada por corregir)."
  fi
  return 0
}

# El apply nunca bloquea una transacción de pacman: corre en subshell; si algo
# falla internamente (set -e), se reporta y se sale con 0 igualmente.
set +e
( main "$@" )
rc=$?
set -e

if [ "$CHECK" = "1" ]; then
  exit "$rc"   # 0 = necesita fix, 1 = no hace falta
fi
if [ "$rc" -ne 0 ]; then
  log "ERROR: falló al re-aplicar el fix. Reintenta a mano o revisa omacom/omarchy#14469." >&2
fi
exit 0