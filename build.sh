#!/bin/bash

setup() {
  MACHINE_ARCH=$(gcc -dumpmachine|cut -d- -f1)
  case $MACHINE_ARCH in
    x86_64)
      CPU_ARCH=x86_64
      ;;
    aarch64)
      CPU_ARCH=$(gcc -mcpu=native -### -x c /dev/null 2>&1 | grep -oP 'march=\K[^ "]+' | cut -d+ -f1)
      ;;
    arm)
      CPU_ARCH=$(gcc -march=native -Q --help=target -v 2> /dev/null|grep -- "^  -march"|tr -d ' \t'|cut -d= -f2|cut -d+ -f1)
      ;;
  esac
  export MACHINE_ARCH
  export CPU_ARCH

  # Set CPU-optimized compiler flags
  case $MACHINE_ARCH in
    aarch64)
      export CFLAGS="-mcpu=native -O3 -ffast-math -fdata-sections -ffunction-sections"
      export CXXFLAGS="$CFLAGS"
      # NOOPT=true skips x86 SSE flags in DPF/tap Makefiles; on aarch64 we
      # provide proper flags instead
      export NOOPT=true
      ;;
  esac

  mkdir -p "$WORK_DIR"/build
  mkdir -p "$WORK_DIR"/download
  mkdir -p "$TARGET_DIR"
  mkdir -p "$PREFIX_DIR"
  mkdir -p "$LV2_DIR"
}

parse() {
  NAME=$(yq eval '.plugin.name' "$1")
  VERSION=$(yq eval '.plugin.version' "$1")
  SOURCE_TYPE=$(yq eval '.plugin.source.type' "$1")
  BUILD_COMMANDS=$(yq ".plugin.build" "$1"| sed "s/^- //")
  INSTALL_COMMANDS=$(yq ".plugin.install" "$1"| sed "s/^- //")
  DATA_TYPE=$(yq eval '.plugin.data.type' "$1")
  BUNDLES=$(yq eval '.plugin.bundles[]' "$1" 2>/dev/null)
  DEPENDENCIES=$(yq eval '.plugin.dependencies[]' "$1" 2>/dev/null)
  MODGUI_BRAND=$(yq eval '.plugin.modgui.brand' "$1" 2>/dev/null)
  MODGUI_COLOR=$(yq eval '.plugin.modgui.color' "$1" 2>/dev/null)
  MODGUI_KNOB=$(yq eval '.plugin.modgui.knob' "$1" 2>/dev/null)
  PLUGIN_DIR=$(pwd)/$(dirname "$1")
  SOURCE_DIR="$WORK_DIR/build/$NAME-$VERSION"
}

check_dependencies() {
  if [ -z "$DEPENDENCIES" ]; then
    return 0
  fi
  MISSING=""
  for pkg in $DEPENDENCIES; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      MISSING="$MISSING $pkg"
    fi
  done
  if [ -n "$MISSING" ]; then
    echo "=== Missing dependencies for $NAME:$MISSING ==="
    read -r -p "Install them now? [Y/n] " answer
    case "$answer" in
      [nN]*)
        echo "Skipping $NAME (missing dependencies)"
        return 1
        ;;
      *)
        sudo apt-get install -y $MISSING || return 1
        ;;
    esac
  fi
  return 0
}

download() {
  echo "=== Download: $NAME ==="
  case $SOURCE_TYPE in
    http)
      URL=$(yq eval '.plugin.source.url' "$1")
      DOWNLOAD="$WORK_DIR/download/$NAME-$VERSION.tar.gz"
      if [ ! -f "$DOWNLOAD" ]; then
        wget -O "$DOWNLOAD" "$URL"
      fi
      pushd "$WORK_DIR/build" > /dev/null || return 1
      tar xzf "$DOWNLOAD" || { popd > /dev/null; return 1; }
      cd "$NAME"* || { popd > /dev/null; return 1; }
      popd > /dev/null || return 1
      ;;
    git)
      if [ ! -d "$SOURCE_DIR" ]; then
        URL=$(yq eval '.plugin.source.url' "$1")
        pushd "$WORK_DIR/build" > /dev/null || return 1
        git clone --branch "$VERSION" --depth 1 --recurse-submodules "$URL" "$NAME-$VERSION" || { popd > /dev/null; return 1; }
        popd > /dev/null
      fi
      ;;
    *)
      echo "Unknown source type in $1"
      return
      ;;
  esac
}

prepare() {
  echo "=== Patch: $NAME ==="
  find "$PLUGIN_DIR" -name "*.patch" -type f -print -exec patch -d "$SOURCE_DIR" -N -p1 -i {} \;
  if [ -d "$PLUGIN_DIR/overlay" ]; then
     cp -rv "$PLUGIN_DIR"/overlay/* "$SOURCE_DIR"
  fi 
}

build() {
  pushd "$SOURCE_DIR" > /dev/null || return 1
  while IFS= read -r line; do
      echo "Executing: $line"
      if ! eval "$line"; then
        echo "FAILED: $NAME (build command: $line)"
        popd > /dev/null
        return 1
      fi
  done <<< "$BUILD_COMMANDS"
  popd > /dev/null
}

install() {
  echo "=== Install: $NAME ==="
  if [ -n "$BUNDLES" ]; then
    PLUGINS="$BUNDLES"
  else
    PLUGINS=$(find "$SOURCE_DIR" -type d -name "*.lv2" -exec basename {} \;| sort|uniq)
  fi
  echo "Bundles:"
  echo "$PLUGINS"
  pushd "$SOURCE_DIR" > /dev/null || return 1
  while IFS= read -r line; do
      echo "Executing: ${line}"
      if ! eval "$line"; then
        echo "FAILED: $NAME (install command: $line)"
        popd > /dev/null
        return 1
      fi
  done <<< "$INSTALL_COMMANDS"
  popd > /dev/null

  case $DATA_TYPE in
    local)
      ;;
    null)
      for PLUGIN in $PLUGINS; do
        find "$DIR/data" -name "$PLUGIN" -type d -exec cp -rv {} "$LV2_DIR" \;
      done
      ;;
    *)
      find "$DIR/data" -name "$DATA_TYPE" -type d -exec cp -rv {} "$LV2_DIR" \;
      ;;
  esac
}

package() {
  echo "=== Package: $NAME ==="
  BUILD_DATE=$(git -C "$SOURCE_DIR" log -1 --format=%cd --date=format:%Y%m%d 2>/dev/null || date +%Y%m%d)
  PACKAGE_DIR="$WORK_DIR/packages"
  mkdir -p "$PACKAGE_DIR"
  for BUNDLE in $PLUGINS; do
    BUNDLE_PATH="$LV2_DIR/$BUNDLE"
    if [ ! -d "$BUNDLE_PATH" ]; then
      echo "Warning: bundle $BUNDLE not found at $BUNDLE_PATH, skipping"
      continue
    fi
    ARCHIVE_NAME="${BUNDLE%.lv2}-${VERSION}-${BUILD_DATE}-${MACHINE_ARCH}.tar.gz"
    tar -czf "$PACKAGE_DIR/$ARCHIVE_NAME" -C "$LV2_DIR" "$BUNDLE"
    echo "Packaged: $PACKAGE_DIR/$ARCHIVE_NAME"
  done
}

BOX_COLORS=(black blue brown cream cyan darkblue dots flowerpower gold gray green lava orange petrol pink purple racing red slime tribal1 tribal2 warning white wood0 wood1 wood2 wood3 wood4 yellow zinc)
KNOB_COLORS=(aluminium black blue bronze copper gold green petrol purple silver steel)

pick_style() {
  local name="$1" seed="$2"
  shift 2
  local arr=("$@")
  local hash=$(echo -n "${name}${seed}" | cksum | cut -d' ' -f1)
  echo "${arr[$((hash % ${#arr[@]}))]}"
}

generate_modgui() {
  [ "$MODGUI_BRAND" = "null" ] && return
  local RESOURCE_DIR="$RESOLVED_DIR/data/modgui-resources"
  [ -d "$RESOURCE_DIR" ] || { echo "Warning: modgui resources not found at $RESOURCE_DIR"; return; }

  for bundle in $PLUGINS; do
    local bundle_dir="$LV2_DIR/$bundle"
    [ -d "$bundle_dir" ] || continue
    [ -d "$bundle_dir/modgui" ] && continue

    local bundle_name=$(basename "$bundle_dir")
    local plugin_short="${bundle_name%.lv2}"
    local lower_name=$(echo "$plugin_short" | tr '[:upper:]' '[:lower:]')

    # Find plugin TTL (not manifest/modgui)
    local ttl_file=$(find "$bundle_dir" -name "*.ttl" ! -name "manifest.ttl" ! -name "modgui.ttl" | head -1)
    [ -z "$ttl_file" ] && continue

    # Get plugin URI and display name
    local uri=$(grep -B1 'a lv2:Plugin' "$bundle_dir/manifest.ttl" | grep -oP '<[^>]+>' | grep -v 'lv2plug.in' | head -1 | tr -d '<>')
    [ -z "$uri" ] && continue
    local display_name=$(grep 'doap:name' "$ttl_file" | head -1 | grep -oP '"[^"]+"' | tr -d '"')
    [ -z "$display_name" ] && display_name="$plugin_short"

    # Parse control ports
    local ports_data=$(python3 -c "
import re
with open('$ttl_file') as f:
    content = f.read()
ports = re.split(r'\] [,.]', content)
results = []
for port in ports:
    if 'ControlPort' in port and 'InputPort' in port:
        idx_m = re.search(r'lv2:index\s+(\d+)', port)
        sym_m = re.search(r'lv2:symbol\s+\"([^\"]+)\"', port)
        name_m = re.search(r'lv2:name\s+\"([^\"]+)\"', port)
        if idx_m and sym_m and name_m:
            results.append((int(idx_m.group(1)), sym_m.group(1), name_m.group(1)))
results.sort()
for idx, sym, name in results:
    print(f'{idx}|{sym}|{name}')
" 2>/dev/null)
    local num_ports=0
    [ -n "$ports_data" ] && num_ports=$(echo "$ports_data" | grep -c '|')

    # Determine styles
    local box_color="$MODGUI_COLOR"
    [ "$box_color" = "null" ] && box_color=$(pick_style "$plugin_short" "" "${BOX_COLORS[@]}")
    local knob_color="$MODGUI_KNOB"
    [ "$knob_color" = "null" ] && knob_color=$(pick_style "$plugin_short" "knob" "${KNOB_COLORS[@]}")
    local brand="$MODGUI_BRAND"

    # Panel info from port count
    local panel model css_class
    case $num_ports in
      0) panel="1-footswitch"; model="boxy-small"; css_class="mod-one-footswitch";;
      1) panel="1-knob"; model="boxy"; css_class="mod-one-knob";;
      2) panel="2-knobs"; model="boxy"; css_class="mod-two-knobs";;
      3) panel="3-knobs"; model="boxy"; css_class="mod-three-knobs";;
      4) panel="4-knobs"; model="boxy"; css_class="mod-four-knobs";;
      5) panel="5-knobs"; model="boxy"; css_class="mod-five-knobs";;
      6) panel="6-knobs"; model="boxy"; css_class="mod-six-knobs";;
      7) panel="7-knobs"; model="boxy"; css_class="mod-seven-knobs";;
      *) panel="8-knobs"; model="boxy"; css_class="mod-eight-knobs";;
    esac

    echo "MODGUI: $bundle_name ($num_ports knobs, $model, $box_color, knob=$knob_color)"

    # Create modgui directory and copy resources
    mkdir -p "$bundle_dir/modgui/pedals/$model"
    [ -f "$RESOURCE_DIR/pedals/$model/$box_color.png" ] && cp "$RESOURCE_DIR/pedals/$model/$box_color.png" "$bundle_dir/modgui/pedals/$model/"
    [ -f "$RESOURCE_DIR/pedals/footswitch.png" ] && cp "$RESOURCE_DIR/pedals/footswitch.png" "$bundle_dir/modgui/pedals/"
    # Generate screenshot from pedal background + brand/label text
    local pedal_bg="$RESOURCE_DIR/pedals/$model/$box_color.png"
    [ ! -f "$pedal_bg" ] && pedal_bg="$RESOURCE_DIR/pedals/boxy/$box_color.png"
    local scrn="$bundle_dir/modgui/screenshot-$lower_name.png"
    local thumb="$bundle_dir/modgui/thumbnail-$lower_name.png"
    if [ -f "$pedal_bg" ] && command -v convert >/dev/null 2>&1; then
      local brand_y=170 label_y=280
      [ "$model" = "boxy-small" ] && brand_y=20 && label_y=85
      convert "$pedal_bg" \
        -font Helvetica-Bold -pointsize 16 -fill black \
        -gravity North -annotate +0+"$brand_y" "$brand" \
        -pointsize 14 -annotate +0+"$label_y" "$display_name" \
        "$scrn"
      convert "$scrn" -resize 64x64 "$thumb"
    else
      cp "$RESOURCE_DIR/pedals/default-screenshot.png" "$scrn"
      cp "$RESOURCE_DIR/pedals/default-thumbnail.png" "$thumb"
    fi

    # Copy knob images
    if [ "$num_ports" -gt 0 ]; then
      mkdir -p "$bundle_dir/modgui/knobs/boxy"
      cp "$RESOURCE_DIR/knobs/boxy/$knob_color.png" "$bundle_dir/modgui/knobs/boxy/" 2>/dev/null
      cp "$RESOURCE_DIR/knobs/boxy/boxy.png" "$bundle_dir/modgui/knobs/boxy/" 2>/dev/null
    fi

    # CSS — /resources/ paths are served from plugin's resourcesDirectory via ?uri= param
    cat "$RESOURCE_DIR/pedals/$model/$model.css" > "$bundle_dir/modgui/stylesheet-$lower_name.css" 2>/dev/null || \
    cat "$RESOURCE_DIR/pedals/boxy/boxy.css" > "$bundle_dir/modgui/stylesheet-$lower_name.css"
    [ "$num_ports" -gt 0 ] && cat "$RESOURCE_DIR/knobs/boxy/boxy.css" >> "$bundle_dir/modgui/stylesheet-$lower_name.css"

    # HTML template
    if [ "$num_ports" -eq 0 ]; then
      cat > "$bundle_dir/modgui/icon-$lower_name.html" << 'HTMLEOF'
<div class="mod-pedal mod-pedal-boxy{{{cns}}} mod-boxy50 mod-one-footswitch mod-{{color}} {{color}}">
    <div mod-role="drag-handle" class="mod-drag-handle"></div>
    <div class="mod-plugin-brand"><h1>{{brand}}</h1></div>
    <div class="mod-plugin-name"><h1>{{label}}</h1></div>
    <div class="mod-light on" mod-role="bypass-light"></div>
    <div class="mod-footswitch" mod-role="bypass"></div>
    <div class="mod-pedal-input">
        {{#effect.ports.audio.input}}
        <div class="mod-input mod-input-disconnected" title="{{name}}" mod-role="input-audio-port" mod-port-symbol="{{symbol}}">
            <div class="mod-pedal-input-image"></div>
        </div>
        {{/effect.ports.audio.input}}
    </div>
    <div class="mod-pedal-output">
        {{#effect.ports.audio.output}}
        <div class="mod-output mod-output-disconnected" title="{{name}}" mod-role="output-audio-port" mod-port-symbol="{{symbol}}">
            <div class="mod-pedal-output-image"></div>
        </div>
        {{/effect.ports.audio.output}}
    </div>
</div>
HTMLEOF
    else
      cat > "$bundle_dir/modgui/icon-$lower_name.html" << HTMLEOF
<div class="mod-pedal mod-pedal-boxy{{{cns}}} $css_class mod-{{color}} {{color}}">
    <div mod-role="drag-handle" class="mod-drag-handle"></div>
    <div class="mod-plugin-brand"><h1>{{brand}}</h1></div>
    <div class="mod-plugin-name"><h1>{{label}}</h1></div>
    <div class="mod-light on" mod-role="bypass-light"></div>
    <div class="mod-control-group mod-{{knob}} clearfix">
        {{#controls}}
        <div class="mod-knob" title="{{comment}}">
            <div class="mod-knob-image" mod-role="input-control-port" mod-port-symbol="{{symbol}}"></div>
            <span class="mod-knob-title">{{name}}</span>
        </div>
        {{/controls}}
    </div>
    <div class="mod-footswitch" mod-role="bypass"></div>
    <div class="mod-pedal-input">
        {{#effect.ports.audio.input}}
        <div class="mod-input mod-input-disconnected" title="{{name}}" mod-role="input-audio-port" mod-port-symbol="{{symbol}}">
            <div class="mod-pedal-input-image"></div>
        </div>
        {{/effect.ports.audio.input}}
    </div>
    <div class="mod-pedal-output">
        {{#effect.ports.audio.output}}
        <div class="mod-output mod-output-disconnected" title="{{name}}" mod-role="output-audio-port" mod-port-symbol="{{symbol}}">
            <div class="mod-pedal-output-image"></div>
        </div>
        {{/effect.ports.audio.output}}
    </div>
</div>
HTMLEOF
    fi

    # Generate modgui.ttl
    {
      echo '@prefix modgui: <http://moddevices.com/ns/modgui#> .'
      echo '@prefix lv2:    <http://lv2plug.in/ns/lv2core#> .'
      echo ''
      echo "<$uri>"
      echo '    modgui:gui ['
      echo "        modgui:resourcesDirectory <modgui> ;"
      echo "        modgui:iconTemplate <modgui/icon-$lower_name.html> ;"
      echo "        modgui:stylesheet <modgui/stylesheet-$lower_name.css> ;"
      echo "        modgui:screenshot <modgui/screenshot-$lower_name.png> ;"
      echo "        modgui:thumbnail <modgui/thumbnail-$lower_name.png> ;"
      echo "        modgui:brand \"$brand\" ;"
      echo "        modgui:label \"$display_name\" ;"
      echo "        modgui:model \"$model\" ;"
      echo "        modgui:panel \"$panel\" ;"
      echo "        modgui:color \"$box_color\" ;"
      if [ "$num_ports" -gt 0 ]; then
        echo "        modgui:knob \"$knob_color\" ;"
        local first=true
        while IFS='|' read -r idx sym pname; do
          [ -z "$idx" ] && continue
          if [ "$first" = true ]; then
            echo '        modgui:port ['
            first=false
          else
            echo '        ] , ['
          fi
          echo "            lv2:index $idx ;"
          echo "            lv2:symbol \"$sym\" ;"
          echo "            lv2:name \"$pname\" ;"
        done <<< "$ports_data"
        echo '        ] ;'
      fi
      echo '    ] .'
    } > "$bundle_dir/modgui.ttl"

    # Add modgui.ttl reference to manifest.ttl
    if ! grep -q "modgui.ttl" "$bundle_dir/manifest.ttl"; then
      # Ensure rdfs prefix exists
      grep -q 'rdfs:' "$bundle_dir/manifest.ttl" || sed -i '1i @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .' "$bundle_dir/manifest.ttl"
      echo "<$uri> rdfs:seeAlso <modgui.ttl> ." >> "$bundle_dir/manifest.ttl"
    fi
  done
}

clean() {
  rm -rf "$SOURCE_DIR"
  rm -f "$WORK_DIR/build/.stamp-$NAME"
}

compute_build_sha() {
  local sha=""
  # Source commit SHA (if git repo exists)
  if [ -d "$SOURCE_DIR/.git" ]; then
    sha=$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null)
  fi
  # Hash the descriptor and patches to detect build rule changes
  local config_hash=$(cat "$PLUGIN_DIR/descriptor.yaml" "$PLUGIN_DIR"/*.patch 2>/dev/null | sha1sum | cut -d' ' -f1)
  echo "${sha}-${config_hash}"
}

is_up_to_date() {
  local stamp_file="$WORK_DIR/build/.stamp-$NAME"
  [ ! -f "$stamp_file" ] && return 1
  local current_sha=$(compute_build_sha)
  local stored_sha=$(cat "$stamp_file")
  [ "$current_sha" = "$stored_sha" ]
}

save_build_sha() {
  compute_build_sha > "$WORK_DIR/build/.stamp-$NAME"
}

### Environment variables
DIR=$(dirname "$0")
RESOLVED_DIR=$(cd "$DIR" >/dev/null; pwd)
WORK_DIR=$RESOLVED_DIR/work
export TARGET_DIR="$WORK_DIR/target"
export PREFIX_DIR="$TARGET_DIR/usr"
export LV2_DIR="$PREFIX_DIR/lib/lv2"
export DATA_DIR="$RESOLVED_DIR/data"
CLEAN=false

while true
do
  case "$1" in
    --clean)
      CLEAN=true
      shift
      ;;
    *)
      break;;
  esac
done

setup
FAILED_PLUGINS=()
SUCCEEDED=0
for PLUGIN in "$@"; do
  DESC="$DIR/plugins/$PLUGIN/descriptor.yaml"
  if [ -f "$DESC" ]; then
    parse "$DESC"
    echo "Plugin: $PLUGIN"
    if ! check_dependencies; then
      FAILED_PLUGINS+=("$PLUGIN (missing dependencies)")
      continue
    fi
    if [ $CLEAN = true ]; then
      clean "$DESC"
    fi
    if ! download "$DESC"; then
      FAILED_PLUGINS+=("$PLUGIN (download)")
      continue
    fi
    if is_up_to_date; then
      echo "=== Up to date: $NAME (skipping) ==="
      SUCCEEDED=$((SUCCEEDED + 1))
      continue
    fi
    prepare "$DESC"
    if ! build "$DESC"; then
      FAILED_PLUGINS+=("$PLUGIN (build)")
      continue
    fi
    if ! install "$DESC"; then
      FAILED_PLUGINS+=("$PLUGIN (install)")
      continue
    fi
    generate_modgui
    package
    save_build_sha
    SUCCEEDED=$((SUCCEEDED + 1))
  else
    echo "Plugin $PLUGIN doesn't have a descriptor"
    FAILED_PLUGINS+=("$PLUGIN (no descriptor)")
  fi
done

echo ""
echo "=== Summary ==="
echo "Succeeded: $SUCCEEDED"
echo "Failed: ${#FAILED_PLUGINS[@]}"
if [ ${#FAILED_PLUGINS[@]} -gt 0 ]; then
  echo ""
  echo "Failed plugins:"
  for p in "${FAILED_PLUGINS[@]}"; do
    echo "  - $p"
  done
fi
