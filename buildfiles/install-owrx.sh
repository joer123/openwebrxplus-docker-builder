#!/bin/bash
set -euo pipefail

# shellcheck disable=SC1091
source /common.sh

echo;echo;echo;echo;echo;echo;echo
pinfo "Building ${PRODUCT:-}:${OWRXVERSION:-}..."
pinfo "MAKEFLAGS: ${MAKEFLAGS:-}"
pinfo "BUILD_DATE: ${BUILD_DATE:-}"
pinfo "PLATFORM: ${PLATFORM}"
pinfo "PRODUCT: ${PRODUCT}"
pinfo "VERSION: ${OWRXVERSION:-}"

echo "${BUILD_DATE:-}" > /build-date
echo "${PRODUCT:-}"-"${OWRXVERSION:-${BUILD_DATE:-unknown}}" > /build-image

apt update

pinfo "Installing prebuilt deb packages..."
dpkg -i "$BUILD_CACHE"/librtlsdr0_*.deb
#dpkg -i $BUILD_CACHE/librtlsdr-dev_*.deb
dpkg -i "$BUILD_CACHE"/rtl-sdr_*.deb
if [[ $(uname -m) != "armv7"* ]]; then # disable for armv7 for now... the build is failing
  dpkg -i "$BUILD_CACHE"/soapysdr0.8-module-airspyhf_*.deb
  dpkg -i "$BUILD_CACHE"/soapysdr-module-airspyhf_*.deb
fi
dpkg -i "$BUILD_CACHE"/soapysdr0.8-module-plutosdr_*.deb
dpkg -i "$BUILD_CACHE"/soapysdr-module-plutosdr_*.deb
dpkg -i "$BUILD_CACHE"/runds-connector_*.deb

echo "If you need SatDump, you can get the AppImage from https://github.com/SatDump/SatDump/releases/download/nightly/SatDump.AppImage" > /satdump-info.txt

pinfo "Installing rest of the binaries from rootfs..."
cp -av "$BUILD_ROOTFS"/* /
sleep 3

# Failsafe patch for RADE python modules (PyTorch compatibility for Debian Bookworm)
find /usr/local/lib -name "*.py" -type f -exec sed -i 's/from torch.nn.utils.parametrizations import weight_norm/from torch.nn.utils import weight_norm/g' {} +

ldconfig /etc/ld.so.conf.d

pinfo "This is a RELEASE (v${OWRXVERSION:-}) build."
if [ -n "${OWRXVERSION:-}" ]; then
  DEBIAN_FRONTEND=noninteractive apt install -y --install-recommends openwebrx="${OWRXVERSION}"
else
  DEBIAN_FRONTEND=noninteractive apt install -y --install-recommends openwebrx
fi
#--install-suggests

# Patch OpenWebRX+ backend for FreeDV-U/L support
if [ -f /usr/lib/python3/dist-packages/owrx/modes.py ]; then
  pinfo "Patching OpenWebRX+ backend files..."
  cat << 'EOF' | python3
import re
import os
import sys

modes_path = "/usr/lib/python3/dist-packages/owrx/modes.py"
dsp_path = "/usr/lib/python3/dist-packages/owrx/dsp.py"
chain_path = "/usr/lib/python3/dist-packages/csdr/chain/freedv.py"
module_path = "/usr/lib/python3/dist-packages/csdr/module/freedv.py"
feature_path = "/usr/lib/python3/dist-packages/owrx/feature.py"

# 1. Patch modes.py to register new modes
with open(modes_path, "r") as f:
    modes_content = f.read()

if "freedv_u" not in modes_content:
    print("Injecting FreeDV-U/L into modes.py...")
    modes_content += "\n" + """
Modes.mappings.extend([
    AnalogMode("freedv_u", "FreeDV-U", bandpass=Bandpass(0, 3000), requirements=["digital_voice_freedv_ka9q"], squelch=False),
    AnalogMode("freedv_l", "FreeDV-L", bandpass=Bandpass(-3000, 0), requirements=["digital_voice_freedv_ka9q"], squelch=False)
])
"""
    with open(modes_path, "w") as f:
        f.write(modes_content)

# 2. Patch owrx/dsp.py to allow underscores in mode names and handle new modes
if os.path.exists(dsp_path):
    with open(dsp_path, "r") as f:
        dsp_content = f.read()
    
    # Allow underscores in ModulationValidator regex
    # Fallback regex replacement for validator if string replace failed
    dsp_content = re.sub(r're\.compile\(([\'"])\^\[a-z0-9\\\\-\]\+\$\1\)', r're.compile(\1^[a-z0-9\\-_]+$\1)', dsp_content)
    
    # Add new modes to factory and pass 'demod' string to FreeDV constructor
    # 1. Patch the list of supported modes
    # Look for a list containing "freedv"
    list_regex = re.compile(r'(\[[^\]]*[\'"]freedv[\'"][^\]]*\])', re.DOTALL)
    match = list_regex.search(dsp_content)
    
    if match:
        print(f"Found FreeDV list: {match.group(1)}")
        if "freedv_u" not in match.group(1):
            # Insert new modes before the closing bracket
            new_list = match.group(1).strip()
            # Handle trailing comma if present
            if new_list.endswith(",]"):
                 new_list = new_list[:-2] + ', "freedv_u", "freedv_l"]'
            elif new_list.endswith("]"):
                 new_list = new_list[:-1] + ', "freedv_u", "freedv_l"]'
            
            dsp_content = dsp_content.replace(match.group(1), new_list)
            print("Patched FreeDV list.")
    elif re.search(r'(==\s*[\'"]freedv[\'"])', dsp_content):
        print("Found FreeDV equality check, patching to list check...")
        dsp_content = re.sub(r'(==\s*[\'"]freedv[\'"])', 'in ["freedv", "freedv_u", "freedv_l"]', dsp_content)
    else:
        print("Error: Could not find FreeDV mode list in dsp.py")
        # Debug output to see why it failed
        start = dsp_content.find("freedv")
        if start != -1:
             print(f"Context around 'freedv':\n{dsp_content[max(0, start-100):start+100]}")
        else:
             print("String 'freedv' not found in dsp.py at all.")
        sys.exit(1)

    # 2. Patch the constructor to pass 'mod'
    # Replace FreeDV() with FreeDV(mod)
    # Dynamically find the argument name of _getDemodulator
    arg_match = re.search(r'def\s+_getDemodulator\s*\(\s*self\s*,\s*([a-zA-Z0-9_]+)', dsp_content)
    if arg_match:
        arg_name = arg_match.group(1)
        print(f"Found _getDemodulator argument: {arg_name}")
        dsp_content = re.sub(r'(FreeDV)\s*\(\s*\)', f'\\1({arg_name})', dsp_content)
        print(f"Patched FreeDV constructor with argument '{arg_name}'.")
    else:
        print("Error: Could not find _getDemodulator definition in dsp.py")

        start = dsp_content.find("def _getDemodulator")
        if start != -1:
             print(f"Context around '_getDemodulator':\n{dsp_content[max(0, start-50):start+100]}")
        else:
             print("String 'def _getDemodulator' not found in dsp.py")
        sys.exit(1)
        
    with open(dsp_path, "w") as f:
        f.write(dsp_content)
    print("Patched owrx/dsp.py")

# 3. Patch csdr/chain/freedv.py to accept mode argument
if os.path.exists(chain_path):
    with open(chain_path, "r") as f:
        chain_content = f.read()
        
    chain_content = re.sub(r"def __init__\(self\)\s*:", "def __init__(self, mode='freedv'):", chain_content)
    chain_content = re.sub(r"FreeDVModule\s*\(\s*\)", "FreeDVModule(mode)", chain_content)
    
    with open(chain_path, "w") as f:
        f.write(chain_content)
    print("Patched csdr/chain/freedv.py")

# 4. Patch csdr/module/freedv.py to select binary based on mode
if os.path.exists(module_path):
    with open(module_path, "r") as f:
        module_content = f.read()
        
    # Rewrite __init__ to handle mode and binary selection
    pattern = re.compile(r"def __init__\(self.*?\):.*?super\(\).__init__\(.*?\[([\'\"])freedv_rx\1.*?\].*?\)", re.DOTALL)
    new_init = """def __init__(self, mode='freedv'):
        binary = "freedv_rx"
        if mode in ["freedv_u", "freedv_l"]:
            binary = "freedv_rade"
        super().__init__(
            Format.SHORT,
            Format.SHORT,
            [binary, "1600", "-", "-"]
        )"""
    module_content = pattern.sub(new_init, module_content)
    
    with open(module_path, "w") as f:
        f.write(module_content)
    print("Patched csdr/module/freedv.py")

# 5. Patch owrx/feature.py to handle mode checks
if os.path.exists(feature_path):
    with open(feature_path, "r") as f:
        feature_content = f.read()
    
    feature_content = feature_content.replace('== "freedv"', 'in ["freedv", "freedv_u", "freedv_l"]')
    feature_content = feature_content.replace("== 'freedv'", "in ['freedv', 'freedv_u', 'freedv_l']")
    
    # Add explicit FreeDV KA9Q feature to the list for visibility
    if "digital_voice_freedv_ka9q" not in feature_content:
        feature_content = feature_content.replace(
            '"digital_voice_freedv": ["freedv_rx"],',
            '"digital_voice_freedv": ["freedv_rx"],\n        "digital_voice_freedv_ka9q": ["freedv_rade"],'
        )
        # Add the checker method for the new requirement
        anchor = 'return self.command_is_runnable("freedv_rx")'
        new_method = '\n\n    def has_freedv_rade(self):\n        """\n        The `freedv_rade` wrapper script is required to use the\n        FreeDV KA9Q modem (RADE) for modes like FreeDV 2020.\n        """\n        return self.command_is_runnable("freedv_rade")'
        if anchor in feature_content:
            feature_content = feature_content.replace(anchor, anchor + new_method)
    
    with open(feature_path, "w") as f:
        f.write(feature_content)
    print("Patched owrx/feature.py")
EOF
fi

# Patch features.js to add description for FreeDV KA9Q
if [ -f /usr/lib/python3/dist-packages/htdocs/features.js ]; then
  pinfo "Patching features.js for FreeDV KA9Q description..."
  cat >> /usr/lib/python3/dist-packages/htdocs/features.js << 'EOF'

if (typeof featureNames !== 'undefined') { featureNames["digital_voice_freedv_ka9q"] = "FreeDV (KA9Q)"; }
if (typeof featureDescriptions !== 'undefined') { featureDescriptions["digital_voice_freedv_ka9q"] = "Support for FreeDV digital voice mode using the KA9Q modem (RADE)."; }
if (typeof requirementNames !== 'undefined') { requirementNames["freedv_rade"] = "FreeDV KA9Q Modem"; }
if (typeof requirementDescriptions !== 'undefined') { requirementDescriptions["freedv_rade"] = "The freedv-ka9q binary is required for RADE-based FreeDV modes."; }
EOF
fi

# Patch openwebrx.js to add UI buttons for FreedvU and FreedvL
if [ -f /usr/lib/python3/dist-packages/htdocs/openwebrx.js ]; then
  pinfo "Patching OpenWebRX frontend for FreedvU/L..."
  # Append the JS wrapper directly, as regex patching is unreliable for the array structure
  cat >> /usr/lib/python3/dist-packages/htdocs/openwebrx.js << 'EOF'
// FreeDV+ Patch: Array-based Injection Wrapper
(function() {
    var original_init = window.openwebrx_init;
    window.openwebrx_init = function() {
        
        if (typeof original_init === 'function') {
            original_init.apply(this, arguments);
        }
        
        // After original init, poll for Modes.modes and then inject and update UI.
        var attempts = 0;
        var injector = setInterval(function() {
            attempts++;
            if (typeof window.Modes !== 'undefined' && Array.isArray(window.Modes.modes) && window.Modes.modes.length > 0) {
                
                var already_patched = window.Modes.modes.some(function(m) { 
                    return (m.id === 'freedv_u') || (m.modulation === 'freedv_u'); 
                });
                if (already_patched) {
                    clearInterval(injector);
                    return;
                }

                // Fuzzy search for freedv base mode
                var freedv_base = window.Modes.modes.find(function(m) {
                    var id = m.id || "";
                    var mod = m.modulation || "";
                    var name = m.name || "";
                    return id.toLowerCase() === 'freedv' || mod.toLowerCase() === 'freedv' || name === 'FreeDV';
                });

                if (!freedv_base) {
                    console.error("[FreeDV+] Could not find a valid 'FreeDV' base mode. Aborting.");
                    clearInterval(injector);
                    return;
                }
                
                var new_u = Object.assign({}, freedv_base);
                new_u.modulation = "freedv_u";
                new_u.name = "FreeDV-U";
                if (new_u.id) new_u.id = "freedv_u";

                var new_l = Object.assign({}, freedv_base);
                new_l.modulation = "freedv_l";
                new_l.name = "FreeDV-L";
                if (new_l.id) new_l.id = "freedv_l";

                // Invert bandpass for LSB
                if (new_l.bandpass) {
                    new_l.bandpass = Object.assign({}, new_l.bandpass);
                    var h = new_l.bandpass.high_cut;
                    var l = new_l.bandpass.low_cut;
                    new_l.bandpass.low_cut = -h;
                    new_l.bandpass.high_cut = -l;
                }

                var newModesList = window.Modes.modes.slice(); // Create a copy
                newModesList.push(new_u);
                newModesList.push(new_l);

                if (typeof window.Modes.setModes === 'function') {
                    window.Modes.setModes(newModesList);
                } else {
                    console.error("[FreeDV+] setModes function not found!");
                }

                clearInterval(injector);

            } else if (attempts > 50) { // Try for 5 seconds
                console.error("[FreeDV+] Injector timed out. Modes.modes array not found or is empty.");
                clearInterval(injector);
            }
        }, 100);
    };
})();
EOF
fi

# add custom.css to OWRX
grep -q 'custom-freedv' /usr/lib/python3/dist-packages/htdocs/index.html || sed -i 's|</head>|<style id="custom-freedv">/* FreeDV+ Custom CSS */\n[data-mode="freedv_u"], [data-mode="freedv_l"] { background-color: #007bff !important; color: white !important; border: 1px solid white; }\n</style>\n</head>|' /usr/lib/python3/dist-packages/htdocs/index.html

mkdir -p /owrx-init
cp -a /etc/openwebrx /owrx-init/etc
cp -a /var/lib/openwebrx /owrx-init/var

chmod +x /run.sh

mkdir -p \
  /etc/s6-overlay/s6-rc.d/openwebrx/dependencies.d \
  /etc/s6-overlay/s6-rc.d/user/contents.d

# create openwebrx service
echo longrun > /etc/s6-overlay/s6-rc.d/openwebrx/type
cat > /etc/s6-overlay/s6-rc.d/openwebrx/run << _EOF_
#!/command/execlineb -P
/run.sh
_EOF_
chmod +x /etc/s6-overlay/s6-rc.d/openwebrx/run
touch /etc/s6-overlay/s6-rc.d/user/contents.d/openwebrx

# add dependencies
touch /etc/s6-overlay/s6-rc.d/openwebrx/dependencies.d/codecserver
touch /etc/s6-overlay/s6-rc.d/openwebrx/dependencies.d/sdrplay

# Verify python3-torch is installed (safeguard against docker cache issues)
if ! python3 -c "import torch" >/dev/null 2>&1 || ! python3 -c "import matplotlib" >/dev/null 2>&1; then
    pwarn "python3-torch or matplotlib not found! Installing torch, scipy and matplotlib..."
    apt install -y --no-install-recommends python3-torch python3-scipy python3-matplotlib
fi

# Ensure python packages are readable by all users (fix for potential permission issues)
chmod -R a+r /usr/local/lib/python*/dist-packages /usr/lib/python3/dist-packages

# Create freedv_rade wrapper
PYVER=$(python3 -c "import sys; print(f'python{sys.version_info.major}.{sys.version_info.minor}')")
cat > /usr/bin/freedv_rade << EOF
#!/bin/bash
# Wrapper for freedv-ka9q
export PYTHONPATH=/usr/local/lib/$PYVER/dist-packages:/usr/lib/python3/dist-packages:\${PYTHONPATH:-}
# Configure freedv-ka9q to output 8kHz directly (OpenWebRX standard)
exec /usr/local/bin/freedv-ka9q --output-sample-rate 8000 "\$@"
EOF
chmod +x /usr/bin/freedv_rade

pwarn "Tiny image..."
rm -f /etc/apt/apt.conf.d/51cache
apt clean
rm -rf /var/lib/apt/lists/*
find / -iname "*.a" -exec rm {} \;
find / -iname "*-old" -exec rm -rf {} \;

pok "Final image done."
