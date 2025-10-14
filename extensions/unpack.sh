#!/usr/bin/env bash
set -euo pipefail

# ▄ ▄▀▀▄  ▄ ▄ ▄▄▄ ▄▄▄ ▄▄▄ ▄▄▄ ▄ ▄    ▄▄ ▄ ▄
# █ ▀▄ █  █ █ █ █ █▄█ █▄█ █   █▀▄   ▀▀▄ █▀█
#  ▀▄▄▄▀  ▀▀▀ ▀ ▀ ▀   ▀ ▀ ▀▀▀ ▀ ▀ ▀ ▀▀  ▀ ▀
#
# ID: unpack.sh
# Author: kinomoto <dev@dc5v.com>
# -----
# Usage: ./unpack.sh [-p|--purge] [-o|--overwrite] [-a|--all-extensions] <file|dir>
# Options:
#   -p, --purge           Delete the original archive after successful extraction.
#   -o, --overwrite       Overwrite destination directory if it exists (no suffix -01, -02 ...).
#   -a, --all-extensions  Detect archives magic numbers
# -----

readonly _SCRIPT_NAME="${0##*/}"
readonly _MAGIC_READ_SIZE=16
readonly _TAR_BLOCK_SIZE=512

readonly _EXIT_SUCCESS=0
readonly _EXIT_DEPS_MISSING=1
readonly _EXIT_INVALID_ARGS=2
readonly _EXIT_READ_FAILURE=3
readonly _EXIT_UNSUPPORTED_FORMAT=4

# State
declare -a _FLIST=()
declare -A _EXTRACTORS=()
declare -A _MAGIC_EXTRACTORS=()
declare -a _FAILED_FILES=()
declare -i _TOTAL_FILES=0
declare -i _SUCCESS_COUNT=0
declare -i _TOTAL_SIZE=0

# Options
declare -g _OPT_PURGE=0
declare -g _OPT_OVERWRITE=0
declare -g _OPT_ALL_EXT=0

# Temp / cleanup registry
declare -a _TEMP_DIRS=()

echo
echo -e "\033[33m▄ ▄▀▀▄ \033[37m ▄ ▄ ▄▄▄ ▄▄▄ ▄▄▄ ▄▄▄ ▄ ▄    ▄▄ ▄ ▄\033[0m"
echo -e "\033[33m█ ▀▄ █ \033[37m █ █ █ █ █▄█ █▄█ █   █▀▄   ▀▀▄ █▀█\033[0m"
echo -e "\033[33m ▀▄▄▄▀ \033[37m ▀▀▀ ▀ ▀ ▀   ▀ ▀ ▀▀▀ ▀ ▀ ▀ ▀▀  ▀ ▀\033[0m"
echo; echo

fn_register_tmp(){ _TEMP_DIRS+=("$1"); }
fn_cleanup(){ local d; for d in "${_TEMP_DIRS[@]:-}"; do [[ -n "${d:-}" && -d "$d" ]] && rm -rf -- "$d" 2>/dev/null || true; done }
trap 'echo; echo "SIGINT."; fn_cleanup; exit 130' INT TERM
trap 'fn_cleanup' EXIT

fn_init_extractors() {
  _EXTRACTORS=(
    [zip]=unzip [jar]=unzip [rar]=unrar [7z]=7z [tar]=tar
    [tar.gz]=tar [tgz]=tar [tar.bz2]=tar [tbz2]=tar [tar.xz]=tar [txz]=tar
    [tar.zst]=tar [tzst]=tar [gz]=gzip [bz2]=bzip2 [xz]=xz [zst]=zstd
    [Z]=uncompress [lz]=lzip [lzma]=lzma [lz4]=lz4 [br]=brotli
  )
  _MAGIC_EXTRACTORS=(
    [gzip]=gzip [zip]=unzip [zip-empty]=unzip [zip-spanned]=unzip
    [bzip2]=bzip2 [xz]=xz [7z]=7z [rar]=unrar [rar5]=unrar [zstd]=zstd
    [lz4]=lz4 [lzip]=lzip [compress]=uncompress [pack]=uncompress
    [brotli]=brotli [tar]=tar
    [cpio-newc]=cpio [cpio-crc]=cpio [cpio-odc]=cpio [cpio-bin]=cpio
    [deb]=ar [ar]=ar [rpm]=rpm2cpio [cab]=cabextract [iso]=7z [dmg]=7z
    [ace]=unace [arj]=arj [lha]=lha [sit]=unsit
  )
}

fn_filesize() {
  local _file="$1"
  if [[ "$OSTYPE" == "darwin"* ]]; then stat -f%z -- "$_file" 2>/dev/null || echo 0
  else stat -c%s -- "$_file" 2>/dev/null || echo 0; fi
}

fn_read_bytes() {
  local _file="$1" _count="$2" _array="$3"
  local _fd _val _char _i=0
  eval "$_array=()"
  exec {_fd}<"$_file" 2>/dev/null || return $_EXIT_READ_FAILURE
  while (( _i < _count  )); do
    if ! IFS= read -r -N 1 -u "$_fd" _char; then break; fi
    if [[ -z "$_char" ]]; then _val=0; else printf -v _val "%d" "'$_char"; fi
    eval "${_array}[$_i]=$_val"; ((_i++))
  done
  exec {_fd}>&-
  return 0
}

fn_check_deb() {
  local _file="$1" _fd _name="" _i=0 _char
  exec {_fd}<"$_file" 2>/dev/null || return 1
  for ((_i=0; _i<8; _i++)); do read -r -N 1 -u "$_fd" _char || { exec {_fd}>&-; return 1; }; done
  _name=""; for ((_i=0; _i<16; _i++)); do IFS= read -r -N 1 -u "$_fd" _char || break; [[ -z "$_char" ]] && _char=$'\x00'; _name+="$_char"; done
  exec {_fd}>&-
  _name="${_name%% *}"; [[ "$_name" == debian-binary* ]] && return 0 || return 1
}

fn_check_cpio() {
  local _file="$1" _len="$2"; local -n _h=$3
  (( _len < 6 )) && return 1
  if (( _h[0]==48 && _h[1]==55 && _h[2]==48 && _h[3]==55 && _h[4]==48 )); then
    case ${_h[5]} in 49) echo cpio-newc; return 0;; 50) echo cpio-crc; return 0;; 55) echo cpio-odc; return 0;; esac
  fi
  if (( _h[0]==199 && _h[1]==113 )); then echo cpio-bin; return 0; fi
  return 1
}

fn_check_iso() {
  local _file="$1" _buf
  _buf=$(dd if="$_file" bs=1 skip=32769 count=5 2>/dev/null)
  [[ "$_buf" == "CD001" ]] && return 0 || return 1
}

fn_check_tar() {
  local _file="$1"; local -a _blk=()
  fn_read_bytes "$_file" "$_TAR_BLOCK_SIZE" _blk || return 1
  (( ${#_blk[@]} < 512 )) && return 1
  local _nonzero=0; for ((i=0;i<512;i++)); do (( _blk[i]!=0 )) && { _nonzero=1; break; }; done
  (( _nonzero==0 )) && return 1
  local _sum_u=0 _sum_s=0 _b
  for ((i=0;i<512;i++)); do
    if (( i>=148 && i<=155 )); then _b=32; else _b=${_blk[i]}; fi
    (( _sum_u+=_b )); (( _sum_s+= (_b>=128)?(_b-256):_b ))
  done
  local _oct=0 _d
  for ((i=148;i<=154;i++)); do _d=${_blk[i]};
    if (( _d>=48 && _d<=55 )); then (( _oct = (_oct<<3) + (_d-48) )); elif (( _d==0 || _d==32 )); then break; fi
  done
  local _is_ustar=0; (( _blk[257]==117 && _blk[258]==115 && _blk[259]==116 && _blk[260]==97 && _blk[261]==114 )) && _is_ustar=1
  (( _oct==_sum_u || _oct==_sum_s || _is_ustar==1 )) && return 0 || return 1
}

fn_detect_magic() {
  local _file="$1" _fsize; local -a _hdr=()
  [[ -z "$_file" || ! -e "$_file" || ! -r "$_file" || ! -f "$_file" || -L "$_file" ]] && return $_EXIT_INVALID_ARGS
  _fsize=$(fn_filesize "$_file"); (( _fsize==0 )) && return $_EXIT_INVALID_ARGS
  fn_read_bytes "$_file" "$_MAGIC_READ_SIZE" _hdr || return $_EXIT_READ_FAILURE
  local _len=${#_hdr[@]}
  is_eq2(){ (( _len>=2 && _hdr[0]==$1 && _hdr[1]==$2 )); }
  is_eq3(){ (( _len>=3 && _hdr[0]==$1 && _hdr[1]==$2 && _hdr[2]==$3 )); }
  is_eq4(){ (( _len>=4 && _hdr[0]==$1 && _hdr[1]==$2 && _hdr[2]==$3 && _hdr[3]==$4 )); }
  is_eq6(){ (( _len>=6 && _hdr[0]==$1 && _hdr[1]==$2 && _hdr[2]==$3 && _hdr[3]==$4 && _hdr[4]==$5 && _hdr[5]==$6 )); }
  is_eq8(){ (( _len>=8 && _hdr[0]==$1 && _hdr[1]==$2 && _hdr[2]==$3 && _hdr[3]==$4 && _hdr[4]==$5 && _hdr[5]==$6 && _hdr[6]==$7 && _hdr[7]==$8 )); }
  is_eq2 31 139 && { echo gzip; return 0; }
  is_eq4 80 75 3 4 && { echo zip; return 0; }
  is_eq4 80 75 5 6 && { echo zip-empty; return 0; }
  is_eq4 80 75 7 8 && { echo zip-spanned; return 0; }
  is_eq3 66 90 104 && { echo bzip2; return 0; }
  is_eq6 253 55 122 88 90 0 && { echo xz; return 0; }
  is_eq6 55 122 188 175 39 28 && { echo 7z; return 0; }
  is_eq8 82 97 114 33 26 7 0 0 && { echo rar; return 0; }
  is_eq8 82 97 114 33 26 7 1 0 && { echo rar5; return 0; }
  is_eq4 40 181 47 253 && { echo zstd; return 0; }
  is_eq4 4 34 77 24 && { echo lz4; return 0; }
  is_eq4 76 90 73 80 && { echo lzip; return 0; }
  is_eq2 31 157 && { echo compress; return 0; }
  is_eq2 31 160 && { echo pack; return 0; }
  is_eq4 206 178 207 129 && { echo brotli; return 0; }
  is_eq4 237 171 238 219 && { echo rpm; return 0; }
  is_eq8 33 60 97 114 99 104 62 10 && { fn_check_deb "$_file" && { echo deb; return 0; }; echo ar; return 0; }
  is_eq4 77 83 67 70 && { echo cab; return 0; }
  fn_check_iso "$_file" && { echo iso; return 0; }
  is_eq4 120 1 115 218 && { echo dmg; return 0; }
  is_eq4 107 111 108 121 && { echo dmg; return 0; }
  fn_check_cpio "$_file" "$_len" _hdr && return 0
  fn_check_tar "$_file" && { echo tar; return 0; }
  is_eq8 42 42 65 67 69 42 42 0 && { echo ace; return 0; }
  is_eq2 96 234 && { echo arj; return 0; }
  is_eq2 45 108 && [[ ${_hdr[2]} == 104 ]] && { echo lha; return 0; }
  is_eq4 83 73 84 33 && { echo sit; return 0; }
  is_eq4 83 116 117 102 && { echo sit; return 0; }
  return $_EXIT_UNSUPPORTED_FORMAT
}

fn_get_extension() {
  local _fname="${1##*/}" _ext=""
  if [[ "$_fname" =~ \.(tar\.(gz|bz2|xz|zst))$ ]]; then _ext="${BASH_REMATCH[1]}"
  elif [[ "$_fname" =~ \.(tgz|tbz2|txz|tzst)$ ]]; then
    case "${BASH_REMATCH[1]}" in tgz) _ext=tar.gz;; tbz2) _ext=tar.bz2;; txz) _ext=tar.xz;; tzst) _ext=tar.zst;; esac
  elif [[ "$_fname" =~ \.([^.]+)$ ]]; then _ext="${BASH_REMATCH[1]}"; fi
  echo "$_ext"
}

fn_add_file() {
  local _file="$1" _ext _magic_type
  [[ ! -f "$_file" ]] && return
  _ext=$(fn_get_extension "$_file")
  if [[ -n "$_ext" && -n "${_EXTRACTORS[$_ext]:-}" ]]; then _FLIST+=("$_file"); return; fi
  if (( _OPT_ALL_EXT==1 )); then
    _magic_type=$(fn_detect_magic "$_file" 2>/dev/null || true)
    if [[ -n "$_magic_type" && -n "${_MAGIC_EXTRACTORS[$_magic_type]:-}" ]]; then _FLIST+=("$_file"); fi
  fi
}

fn_collect_archives() { local _dir="$1" _file; while IFS= read -r -d '' _file; do fn_add_file "$_file"; done < <(find "$_dir" -maxdepth 1 -type f -print0 2>/dev/null); }

fn_parse_args() {
  local _args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--purge) _OPT_PURGE=1; shift;;
      -o|--overwrite|-f|--force) _OPT_OVERWRITE=1; shift;;
      -a|--all-extensions) _OPT_ALL_EXT=1; shift;;
      --) shift; break;;
      -*) echo "Error: Unknown option: $1" >&2; exit $_EXIT_INVALID_ARGS;;
      *) _args+=("$1"); shift;;
    esac
  done
  [[ ${#_args[@]} -eq 0 ]] && { echo "Error: No input files specified" >&2; exit $_EXIT_INVALID_ARGS; }

  local _path f
  for _path in "${_args[@]}"; do
    if [[ -d "$_path" ]]; then
      fn_collect_archives "$_path"
    elif [[ -e "$_path" ]]; then
      fn_add_file "$_path"
    else
      shopt -s nullglob
      mapfile -t _expanded < <(compgen -G -- "$_path")
      shopt -u nullglob
      if (( ${#_expanded[@]} )); then for f in "${_expanded[@]}"; do fn_add_file "$f"; done
      else echo "Warning: No files match pattern: $_path" >&2; fi
    fi
  done
  (( ${#_FLIST[@]} )) || { echo "Error: No supported archive files found" >&2; exit $_EXIT_INVALID_ARGS; }
}

fn_check_deps() {
  local -A _deps_map=()
  local _file _ext _magic_type _extractor
  for _file in "${_FLIST[@]}"; do
    _ext=$(fn_get_extension "$_file")
    if [[ -n "$_ext" && -n "${_EXTRACTORS[$_ext]:-}" ]]; then _extractor="${_EXTRACTORS[$_ext]}"
    elif (( _OPT_ALL_EXT==1 )); then _magic_type=$(fn_detect_magic "$_file" 2>/dev/null || true); [[ -n "$_magic_type" ]] && _extractor="${_MAGIC_EXTRACTORS[$_magic_type]:-}"; fi
    [[ -n "${_extractor:-}" ]] && _deps_map["$_extractor"]=1
  done
  if [[ -n "${_deps_map[tar]:-}" ]]; then
    for _file in "${_FLIST[@]}"; do _ext=$(fn_get_extension "$_file"); [[ "$_ext" == tar.zst || "$_ext" == tzst ]] && _deps_map[zstd]=1; done
  fi
  local _dep _missing=()
  for _dep in "${!_deps_map[@]}"; do command -v "$_dep" &>/dev/null || _missing+=("$_dep"); done
  if (( ${#_missing[@]} )); then
    echo "Error: Missing required dependencies:" >&2
    printf "  - %s\n" "${_missing[@]}" >&2
    echo >&2
    echo "Install missing tools:" >&2
    if [[ "$OSTYPE" == darwin* ]]; then echo "  macOS (Homebrew): brew install ${_missing[*]}" >&2
    elif command -v apt-get &>/dev/null; then echo "  Ubuntu/Debian: sudo apt-get install ${_missing[*]}" >&2
    elif command -v pacman &>/dev/null; then echo "  Arch Linux: sudo pacman -S ${_missing[*]}" >&2
    elif command -v yum &>/dev/null; then echo "  RHEL/CentOS: sudo yum install ${_missing[*]}" >&2
    fi
    exit $_EXIT_DEPS_MISSING
  fi
}

fn_get_unique_dir() {
  local _base="$1" _dir="$_base" _counter=1
  if (( _OPT_OVERWRITE==1 )); then rm -rf -- "$_dir" 2>/dev/null || true; echo "$_dir"; return; fi
  while [[ -e "$_dir" ]]; do _dir=$(printf "%s-%02d" "$_base" "$_counter"); ((_counter++)); (( _counter>999 )) && { echo "Error: Cannot create unique directory for: $_base" >&2; return 1; }; done
  echo "$_dir"
}

fn_get_extract_type() {
  local _file="$1" _ext _magic_type
  _ext=$(fn_get_extension "$_file")
  if [[ -n "$_ext" && -n "${_EXTRACTORS[$_ext]:-}" ]]; then echo "ext:$_ext"; return; fi
  _magic_type=$(fn_detect_magic "$_file" 2>/dev/null || true)
  if [[ -n "$_magic_type" && -n "${_MAGIC_EXTRACTORS[$_magic_type]:-}" ]]; then echo "magic:$_magic_type"; return; fi
  return 1
}

fn_flatten_if_needed() {
  local _src="$1" _dst="$2"
  local -a _entries=() _info_files=()
  local _single_dir=""
  shopt -s nullglob dotglob; _entries=("$_src"/*); shopt -u nullglob dotglob
  if (( ${#_entries[@]}==0 )); then mkdir -p -- "$_dst"; return; fi
  local _e _name _name_upper
  for _e in "${_entries[@]}"; do
    _name="${_e##*/}"; _name_upper="${_name^^}"
    if [[ "$_name_upper" =~ ^(README|LICENSE|LICENCE|COPYING|AUTHORS|CHANGELOG|NOTICE|COPYRIGHT|INSTALL|NEWS|THANKS|TODO|HISTORY)(\..*)?$ ]]; then
      _info_files+=("$_e"); continue
    fi
    if [[ -d "$_e" ]]; then
      if [[ -z "$_single_dir" ]]; then _single_dir="$_e"; else _single_dir=""; break; fi
    else
      _single_dir=""; break
    fi
  done
  mkdir -p -- "$_dst"
  if [[ -n "$_single_dir" ]]; then
    shopt -s nullglob dotglob
    mv -f -- "$_single_dir"/* "$_dst"/ 2>/dev/null || true
    shopt -u nullglob dotglob
    local _info
    for _info in "${_info_files[@]}"; do
      local _bn="${_info##*/}" _t="$_dst/$_bn" _i=1 _stem="${_bn%.*}" _ext="${_bn##*.}"
      while [[ -e "$_t" ]]; do
        if [[ "$_stem" == "$_ext" ]]; then _t=$(printf "%s/owned-%s-%02d" "$_dst" "$_stem" "$_i")
        else _t=$(printf "%s/owned-%s-%02d.%s" "$_dst" "$_stem" "$_i" "$_ext"); fi
        ((_i++))
      done
      mv -f -- "$_info" "$_t" 2>/dev/null || true
    done
  else
    shopt -s nullglob dotglob
    mv -f -- "$_src"/* "$_dst"/ 2>/dev/null || true
    shopt -u nullglob dotglob
  fi
}

fn_zip_count(){
  local _file="$1" _n
  if command -v zipinfo &>/dev/null; then
    _n=$(zipinfo -1 "$1" 2>/dev/null | grep -v '/$' | wc -l)
  else
    _n=$(unzip -Z -1 "$1" 2>/dev/null | grep -v '/$' | wc -l)
  fi
  echo "${_n:-0}"
}

fn_extract() {
  local _file="$1" _fname="${_file##*/}" _dir="${_file%/*}"
  local _type _method _format _base _target_dir _temp_dir _rc=0
  _type=$(fn_get_extract_type "$_file") || return 1
  _method="${_type%%:*}"; _format="${_type#*:}"

  if [[ "$_method" == ext ]]; then
    local _ext="$_format"
    if [[ "$_ext" =~ ^tar\. || "$_ext" =~ ^t[gbx]z || "$_ext" == tzst ]]; then
      _base="${_fname%.*.*}"; [[ "$_ext" =~ ^t[gbx]z|tzst$ ]] && _base="${_fname%.*}".
    else _base="${_fname%.*}"; fi
  else
    _base="$_fname"; local s
    for s in .gz .bz2 .xz .zst .Z .lz .lzma .lz4 .br .tar .zip .rar .7z; do [[ "$_base" == *"$s" ]] && _base="${_base%$s}"; done
  fi

  _target_dir=$(fn_get_unique_dir "$_dir/$_base") || return 1
  _temp_dir=$(mktemp -d "${_target_dir}.tmp.XXXXXX") || return 1; fn_register_tmp "$_temp_dir"

  case "$_format" in
    zip|zip-*) unzip -q "$_file" -d "$_temp_dir" 2>/dev/null || _rc=$? ;;
    rar|rar5)  unrar x -y "$_file" "$_temp_dir"/ >/dev/null 2>&1 || _rc=$? ;;
    7z)        7z x -y -o"$_temp_dir" "$_file" >/dev/null 2>&1 || _rc=$? ;;
    tar)       tar -C "$_temp_dir" -xf "$_file" 2>/dev/null || _rc=$? ;;
    tar.gz|tgz|gzip)
      if [[ "$_format" == gzip ]]; then gzip -dc "$_file" > "$_temp_dir/${_base}" 2>/dev/null || _rc=$?
      else tar -C "$_temp_dir" -xzf "$_file" 2>/dev/null || _rc=$?; fi ;;
    tar.bz2|tbz2|bzip2)
      if [[ "$_format" == bzip2 ]]; then bzip2 -dc "$_file" > "$_temp_dir/${_base}" 2>/dev/null || _rc=$?
      else tar -C "$_temp_dir" -xjf "$_file" 2>/dev/null || _rc=$?; fi ;;
    tar.xz|txz|xz)
      if [[ "$_format" == xz ]]; then xz -dc "$_file" > "$_temp_dir/${_base}" 2>/dev/null || _rc=$?
      else tar -C "$_temp_dir" -xJf "$_file" 2>/dev/null || _rc=$?; fi ;;
    tar.zst|tzst|zstd)
      if [[ "$_format" == zstd ]]; then zstd -dc "$_file" > "$_temp_dir/${_base}" 2>/dev/null || _rc=$?
      else if command -v zstdmt &>/dev/null; then zstdmt -dc "$_file" | tar -C "$_temp_dir" -x 2>/dev/null || _rc=$?
      else zstd -dc "$_file" | tar -C "$_temp_dir" -x 2>/dev/null || _rc=$?; fi; fi ;;
    gz)   gzip -dc "$_file" > "$_temp_dir/${_base}" 2>/dev/null || _rc=$? ;;
    bz2)  bzip2 -dc "$_file" > "$_temp_dir/${_base}" 2>/dev/null || _rc=$? ;;
    Z|compress|pack) uncompress -c "$_file" > "$_temp_dir/${_base}" 2>/dev/null || _rc=$? ;;
    lz|lzip) lzip -dc "$_file" > "$_temp_dir/${_base}" 2>/dev/null || _rc=$? ;;
    lzma) lzma -dc "$_file" > "$_temp_dir/${_base}" 2>/dev/null || _rc=$? ;;
    lz4)  lz4 -dc "$_file" > "$_temp_dir/${_base}" 2>/dev/null || _rc=$? ;;
    br|brotli) brotli -dc "$_file" > "$_temp_dir/${_base}" 2>/dev/null || _rc=$? ;;
    cpio-*) ( cd "$_temp_dir" && cpio -id < "$_file" ) 2>/dev/null || _rc=$? ;;
    deb)
      ( cd "$_temp_dir" && ar x "$_file" ) >/dev/null 2>&1 || _rc=$?
      if [[ -f "$_temp_dir/data.tar.gz" ]]; then tar -C "$_temp_dir" -xzf "$_temp_dir/data.tar.gz" 2>/dev/null; rm -f "$_temp_dir/data.tar.gz" "$_temp_dir/control.tar.gz" "$_temp_dir/debian-binary"
      elif [[ -f "$_temp_dir/data.tar.xz" ]]; then tar -C "$_temp_dir" -xJf "$_temp_dir/data.tar.xz" 2>/dev/null; rm -f "$_temp_dir/data.tar.xz" "$_temp_dir/control.tar.xz" "$_temp_dir/debian-binary"; fi ;;
    ar)   ( cd "$_temp_dir" && ar x "$_file" ) 2>/dev/null || _rc=$? ;;
    rpm)  ( cd "$_temp_dir" && rpm2cpio "$_file" | cpio -id ) 2>/dev/null || _rc=$? ;;
    cab)  cabextract -q -d "$_temp_dir" "$_file" 2>/dev/null || _rc=$? ;;
    iso|dmg) 7z x -y -o"$_temp_dir" "$_file" >/dev/null 2>&1 || _rc=$? ;;
    ace)  unace x -y "$_file" "$_temp_dir"/ >/dev/null 2>&1 || _rc=$? ;;
    arj)  ( cd "$_temp_dir" && arj x -y "$_file" ) >/dev/null 2>&1 || _rc=$? ;;
    lha)  lha xq "$_file" "$_temp_dir"/ 2>/dev/null || _rc=$? ;;
    sit)  unsit "$_file" "$_temp_dir"/ 2>/dev/null || _rc=$? ;;
    *)    return 1;;
  esac

  if (( _rc != 0 )); then return $_rc; fi
  fn_flatten_if_needed "$_temp_dir" "$_target_dir"
  rm -rf -- "$_temp_dir" 2>/dev/null || true

  if [[ -d "$_target_dir" ]]; then
    local _size
    if [[ "$OSTYPE" == "darwin"* ]]; then _size=$(du -sk -- "$_target_dir" 2>/dev/null | cut -f1); _size=$((_size * 1024))
    else _size=$(du -sb -- "$_target_dir" 2>/dev/null | cut -f1); fi
    _TOTAL_SIZE=$((_TOTAL_SIZE + ${_size:-0}))
  fi
  return 0
}

fn_verify_extraction() {
  local _file="$1" _dir="$2" _type _method _format
  [[ ! -d "$_dir" ]] && return 1
  local _count; _count=$(find "$_dir" -type f 2>/dev/null | wc -l)
  (( _count==0 )) && return 1
  _type=$(fn_get_extract_type "$_file" 2>/dev/null || true)
  if [[ -n "$_type" ]]; then _method="${_type%%:*}"; _format="${_type#*:}"; fi
  case "$_format" in
    zip|zip-*)
      local _expected; _expected=$(fn_zip_count "$_file")
      if [[ -n "$_expected" && "$_expected" =~ ^[0-9]+$ ]]; then (( _count < _expected )) && return 1; fi ;;
    tar|tar.*|t[gbx]z*|tzst)
      local _expected; _expected=$(tar -tf "$_file" 2>/dev/null | grep -v '/$' | wc -l)
      if [[ -n "$_expected" && "$_expected" =~ ^[0-9]+$ ]]; then (( _count != _expected )) && return 1; fi ;;
  esac
  return 0
}

fn_find_created_dir() {
  local _base="$1"
  if [[ -d "$_base" ]]; then echo "$_base"; return; fi
  local i
  for i in {01..99}; do [[ -d "${_base}-${i}" ]] && { echo "${_base}-${i}"; return; }; done
  echo "$_base"
}

fn_process_file() {
  local _file="$1" _fname="${_file##*/}" _dir="${_file%/*}" _type _base _target_dir
  printf 'Processing: %s ... ' "$_fname"
  _type=$(fn_get_extract_type "$_file" 2>/dev/null || true)
  if [[ -z "$_type" ]]; then echo 'SKIPPED (unsupported format)'; _FAILED_FILES+=("$_fname: Unsupported format"); return 1; fi
  local _ext; _ext=$(fn_get_extension "$_file")
  if [[ -n "$_ext" ]]; then
    if [[ "$_ext" =~ ^tar\. || "$_ext" =~ ^t[gbx]z || "$_ext" == tzst ]]; then _base="${_fname%.*.*}"; [[ "$_ext" =~ ^t[gbx]z|tzst$ ]] && _base="${_fname%.*}"
    else _base="${_fname%.*}"; fi
  else
    _base="$_fname"; local s; for s in .gz .bz2 .xz .zst .Z .lz .lzma .lz4 .br .tar .zip .rar .7z; do [[ "$_base" == *"$s" ]] && _base="${_base%$s}"; done
  fi
  _target_dir="$_dir/$_base"
  if fn_extract "$_file"; then
    local _actual_dir; _actual_dir=$(fn_find_created_dir "$_target_dir")
    if fn_verify_extraction "$_file" "$_actual_dir"; then
      echo "OK [${_type#*:}]"; ((_SUCCESS_COUNT++))
      if (( _OPT_PURGE==1 )); then rm -f -- "$_file" 2>/dev/null && echo "  -> Original deleted"; fi
      return 0
    else
      echo 'FAILED (verification error)'; _FAILED_FILES+=("$_fname: Extraction verification failed"); [[ -d "$_actual_dir" ]] && rm -rf -- "$_actual_dir"
      return 1
    fi
  else
    echo 'FAILED (extraction error)'; _FAILED_FILES+=("$_fname: Extraction failed")
    return 1
  fi
}

fn_main() {
  fn_init_extractors
  fn_parse_args "$@"

  echo "Found ${#_FLIST[@]} archive(s) to process"; echo

  fn_check_deps
  _TOTAL_FILES=${#_FLIST[@]}

  local _file
  for _file in "${_FLIST[@]}"; do fn_process_file "$_file" || true; done

  echo
  echo "## Result"
  echo "Succeeded: $_SUCCESS_COUNT/$_TOTAL_FILES"
  if (( _TOTAL_SIZE==0 )); then echo "Size: 0"
  else echo "Size: $((_TOTAL_SIZE/1024)) KB"; fi

  if (( ${#_FAILED_FILES[@]} )); then
    echo "## Failed"
    echo "Failed extractions:"; printf "  - %s\n" "${_FAILED_FILES[@]}"
    exit 1
  fi
  exit $_EXIT_SUCCESS
}

fn_main "$@"
