#!/bin/bash
#
# Generate modgui for Airwindows plugins that don't have one.
# Uses boxy pedal model with randomized colors and knob styles.
#
# Usage: ./generate-modgui.sh <lv2-dir> <mod-sdk-dir>

set -e

LV2_DIR="${1:?Usage: $0 <lv2-dir> <mod-sdk-dir>}"
SDK_DIR="${2:?Usage: $0 <lv2-dir> <mod-sdk-dir>}"

# Available styles
BOX_COLORS=(black blue brown cream cyan darkblue dots flowerpower gold gray green lava orange petrol pink purple racing red slime tribal1 tribal2 warning white wood0 wood1 wood2 wood3 wood4 yellow zinc)
KNOB_COLORS=(aluminium black blue bronze copper gold green petrol purple silver steel)

# Deterministic hash-based "random" selection from plugin name
pick_from_array() {
    local name="$1"
    shift
    local arr=("$@")
    local hash=$(echo -n "$name" | cksum | cut -d' ' -f1)
    local idx=$((hash % ${#arr[@]}))
    echo "${arr[$idx]}"
}

# Pick a different element using a different seed
pick_from_array2() {
    local name="$1"
    shift
    local arr=("$@")
    local hash=$(echo -n "${name}knob" | cksum | cut -d' ' -f1)
    local idx=$((hash % ${#arr[@]}))
    echo "${arr[$idx]}"
}

# Map control port count to panel and CSS class
get_panel_info() {
    local count=$1
    case $count in
        0) echo "1-footswitch boxy-small mod-one-footswitch";;
        1) echo "1-knob boxy mod-one-knob";;
        2) echo "2-knobs boxy mod-two-knobs";;
        3) echo "3-knobs boxy mod-three-knobs";;
        4) echo "4-knobs boxy mod-four-knobs";;
        5) echo "5-knobs boxy mod-five-knobs";;
        6) echo "6-knobs boxy mod-six-knobs";;
        7) echo "7-knobs boxy mod-seven-knobs";;
        *) echo "8-knobs boxy mod-eight-knobs";;
    esac
}

# Extract control input ports from TTL
parse_control_ports() {
    local ttl_file="$1"
    # Extract symbol and name for ControlPort InputPort entries
    python3 -c "
import re, sys

with open('$ttl_file') as f:
    content = f.read()

# Split into port blocks
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
"
}

# Get plugin URI from manifest.ttl
get_plugin_uri() {
    # URI is on the line before or same line as 'a lv2:Plugin', and starts with http
    grep -B1 'a lv2:Plugin' "$1/manifest.ttl" | grep -oP '<https?://[^>]+>' | head -1 | tr -d '<>'
}

# Get plugin display name from TTL
get_plugin_name() {
    local ttl_file="$1"
    grep 'doap:name' "$ttl_file" | head -1 | grep -oP '"[^"]+"' | tr -d '"'
}

generated=0
skipped=0

for bundle_dir in "$LV2_DIR"/Airwindows-*.lv2; do
    bundle_name=$(basename "$bundle_dir")
    plugin_short="${bundle_name%.lv2}"
    plugin_short="${plugin_short#Airwindows-}"

    # Skip if modgui already exists
    if [ -d "$bundle_dir/modgui" ]; then
        skipped=$((skipped + 1))
        continue
    fi

    # Find the TTL file (not manifest.ttl or modgui.ttl)
    ttl_file=$(find "$bundle_dir" -name "*.ttl" ! -name "manifest.ttl" ! -name "modgui.ttl" | head -1)
    if [ -z "$ttl_file" ]; then
        echo "SKIP: $bundle_name (no TTL found)"
        continue
    fi

    # Get plugin info
    uri=$(get_plugin_uri "$bundle_dir")
    display_name=$(get_plugin_name "$ttl_file")
    lower_name=$(echo "$plugin_short" | tr '[:upper:]' '[:lower:]')

    # Parse control ports
    ports_data=$(parse_control_ports "$ttl_file")
    num_ports=$(echo "$ports_data" | grep -c '|' 2>/dev/null || echo 0)
    if [ -z "$ports_data" ]; then
        num_ports=0
    fi

    # Pick styles
    box_color=$(pick_from_array "$plugin_short" "${BOX_COLORS[@]}")
    knob_color=$(pick_from_array2 "$plugin_short" "${KNOB_COLORS[@]}")
    panel_info=$(get_panel_info "$num_ports")
    panel=$(echo "$panel_info" | cut -d' ' -f1)
    model=$(echo "$panel_info" | cut -d' ' -f2)
    css_class=$(echo "$panel_info" | cut -d' ' -f3)

    # Truncate brand to fit
    brand="Airwindows"
    if [ ${#display_name} -gt 12 ]; then
        brand="Hannes"
    fi

    echo "GEN: $bundle_name ($num_ports knobs, $model, $box_color, knob=$knob_color)"

    # Create modgui directory
    mkdir -p "$bundle_dir/modgui/pedals/$model"

    # Copy pedal background image
    if [ -f "$SDK_DIR/html/resources/pedals/$model/$box_color.png" ]; then
        cp "$SDK_DIR/html/resources/pedals/$model/$box_color.png" "$bundle_dir/modgui/pedals/$model/"
    fi

    # Copy footswitch
    if [ -f "$SDK_DIR/html/resources/pedals/footswitch.png" ]; then
        cp "$SDK_DIR/html/resources/pedals/footswitch.png" "$bundle_dir/modgui/pedals/"
    fi

    # Copy default screenshot/thumbnail
    cp "$SDK_DIR/html/resources/pedals/default-screenshot.png" "$bundle_dir/modgui/screenshot-$lower_name.png"
    cp "$SDK_DIR/html/resources/pedals/default-thumbnail.png" "$bundle_dir/modgui/thumbnail-$lower_name.png"

    # Generate CSS: base + knobs section if needed
    cat "$SDK_DIR/html/resources/pedals/$model/$model.css" > "$bundle_dir/modgui/stylesheet-$lower_name.css" 2>/dev/null || \
    cat "$SDK_DIR/html/resources/pedals/boxy/boxy.css" > "$bundle_dir/modgui/stylesheet-$lower_name.css"

    if [ "$num_ports" -gt 0 ]; then
        cat "$SDK_DIR/html/resources/knobs/boxy/boxy.css" >> "$bundle_dir/modgui/stylesheet-$lower_name.css"
    fi

    # Generate HTML template
    if [ "$num_ports" -eq 0 ]; then
        # Footswitch-only template
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
        # Knob template
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
            # Port list
            first=true
            while IFS='|' read -r idx sym name; do
                [ -z "$idx" ] && continue
                if [ "$first" = true ]; then
                    echo '        modgui:port ['
                    first=false
                else
                    echo '        ] , ['
                fi
                echo "            lv2:index $idx ;"
                echo "            lv2:symbol \"$sym\" ;"
                echo "            lv2:name \"$name\" ;"
            done <<< "$ports_data"
            echo '        ] ;'
        fi
        echo '    ] .'
    } > "$bundle_dir/modgui.ttl"

    # Add modgui.ttl reference to manifest.ttl if not present
    if ! grep -q "modgui.ttl" "$bundle_dir/manifest.ttl"; then
        echo "<$uri> rdfs:seeAlso <modgui.ttl> ." >> "$bundle_dir/manifest.ttl"
    fi

    generated=$((generated + 1))
done

echo ""
echo "Done: generated $generated modguis, skipped $skipped (already had modgui)"
