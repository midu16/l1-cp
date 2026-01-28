#!/usr/bin/env bash
set -euo pipefail

# --- Configurable variables ---
SOURCE_INDEX="${SOURCE_INDEX:-<your_source_index_here>}"
IMAGESET_OUTPUT_FILE="${IMAGESET_OUTPUT_FILE:-imageset-config.yml}"
DEBUG="${DEBUG:-false}"
USE_VERSION_RANGE="${USE_VERSION_RANGE:-true}"
NO_LIMITATIONS_MODE="${NO_LIMITATIONS_MODE:-false}"
ALLOW_CHANNEL_SPECIFIC_VERSIONS="${ALLOW_CHANNEL_SPECIFIC_VERSIONS:-true}"
OCP_VERSION="${OCP_VERSION:-}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Operators from registry.stage.redhat.io/redhat/redhat-operator-index:v4.20 that should NOT have version constraints
REDHAT_REGISTRY_OPERATORS=(
  "mta-operator"
  "mtc-operator"
  "mtr-operator"
  "mtv-operator"
  "node-observability-operator"
  "cincinnati-operator"
  "container-security-operator"
  "tempo-product"
  "self-node-remediation"
  "ansible-automation-platform-operator"
  "ansible-cloud-addons-operator"
)

# Operators that should NOT have channel, minVersion, or maxVersion constraints
OPERATORS_WITHOUT_VERSION_CONSTRAINTS=(
  "advanced-cluster-management"
  "multicluster-engine"
)

# Debug helper function
debug_log() {
  if [[ "$DEBUG" == "true" ]]; then
    echo "[DEBUG] $*" >&2
  fi
}

# Helper function to check if operator should skip version constraints
is_redhat_registry_operator() {
  local operator="$1"
  for redhat_op in "${REDHAT_REGISTRY_OPERATORS[@]}"; do
    if [[ "$operator" == "$redhat_op" ]]; then
      return 0  # Found in list
    fi
  done
  return 1  # Not found in list
}

# Helper function to check if operator should skip channel and version constraints
should_skip_channel_and_versions() {
  local operator="$1"
  for op in "${OPERATORS_WITHOUT_VERSION_CONSTRAINTS[@]}"; do
    if [[ "$operator" == "$op" ]]; then
      return 0  # Found in list
    fi
  done
  return 1  # Not found
}

# Retry helper function
retry() {
  local retries=$1 delay=$2
  shift 2
  local count=0
  until "$@"; do
    exit_code=$?
    count=$((count + 1))
    if [ "$count" -lt "$retries" ]; then
      echo "Retry $count/$retries failed. Retrying in $delay seconds..."
      sleep "$delay"
    else
      echo "Command failed after $retries attempts."
      return $exit_code
    fi
  done
}

# Version parsing and comparison functions
extract_version() {
  local version_string="$1"
  # Extract version from HEAD column values like:
  # - "aap-operator.v2.5.0-0.1758147230" (from oc-mirror list operators HEAD column)
  # - "openshift-gitops-operator.v1.18.0" (standard format)
  # - "any-operator-name.v1.11.7-0.1724840231.p" (unlimited suffixes)
  # - "operator-prefix.v2.1.0-beta1" (generic operator prefix)
  # - "odf-prometheus-operator.v4.20.0-98.stable" (channel-specific versions)
  # - "some-operator.v4.20.0-98.stable" (generic channel-specific)
  
  local version
  debug_log "Extracting version from: $version_string"
  
  # Generic pattern 1: operator-prefix.v4.20.0-98.stable (channel-specific)
  if [[ "$version_string" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*\.(v?[0-9]+\.[0-9]+\.[0-9]+-[0-9a-zA-Z._-]+)\.(stable|fast|candidate|eus)$ ]]; then
    version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    debug_log "Found generic channel-specific version pattern: $version"
  # Generic pattern 2: operator-prefix.v2.5.0-0.1758147230 (extended unlimited suffixes)  
  elif [[ "$version_string" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*\.(v?[0-9]+\.[0-9]+\.[0-9]+-[0-9a-zA-Z._-]+)$ ]]; then
    version="${BASH_REMATCH[1]}"
    debug_log "Found generic extended version pattern with unlimited suffix: $version"
  # Generic pattern 3: operator-prefix.v4.20.0-98 (standard extended)
  elif [[ "$version_string" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*\.(v?[0-9]+\.[0-9]+\.[0-9]+-[0-9]+)$ ]]; then
    version="${BASH_REMATCH[1]}"
    debug_log "Found generic extended version pattern: $version"
  # Generic pattern 4: operator-prefix.v1.18.0 (semantic version)
  elif [[ "$version_string" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*\.(v?[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    version="${BASH_REMATCH[1]}"
    debug_log "Found generic semantic version: $version"
  # Generic pattern 5: operator-prefix.v1.5 (major.minor)
  elif [[ "$version_string" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*\.(v?[0-9]+\.[0-9]+)$ ]]; then
    version="${BASH_REMATCH[1]}.0"
    debug_log "Found generic major.minor version, padded to: $version"
  # Legacy pattern 1: .v4.20.0-98.stable (backwards compatibility)
  elif [[ "$version_string" =~ \.(v?[0-9]+\.[0-9]+\.[0-9]+-[0-9a-zA-Z._-]+)\.(stable|fast|candidate|eus) ]]; then
    version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    debug_log "Found legacy channel-specific version pattern: $version"
  # Legacy pattern 2: .v2.5.0-0.1758147230 (backwards compatibility)
  elif [[ "$version_string" =~ \.(v?[0-9]+\.[0-9]+\.[0-9]+-[0-9a-zA-Z._-]+) ]]; then
    version="${BASH_REMATCH[1]}"
    debug_log "Found legacy extended version pattern: $version"
  # Legacy pattern 3: .v4.20.0-98 (backwards compatibility)
  elif [[ "$version_string" =~ \.(v?[0-9]+\.[0-9]+\.[0-9]+-[0-9]+) ]]; then
    version="${BASH_REMATCH[1]}"
    debug_log "Found legacy extended version pattern: $version"
  # Legacy pattern 4: .v1.18.0 (backwards compatibility)
  elif [[ "$version_string" =~ \.(v?[0-9]+\.[0-9]+\.[0-9]+) ]]; then
    version="${BASH_REMATCH[1]}"
    debug_log "Found legacy semantic version: $version"
  # Legacy pattern 5: .v1.5 (backwards compatibility)
  elif [[ "$version_string" =~ \.(v?[0-9]+\.[0-9]+) ]]; then
    version="${BASH_REMATCH[1]}.0"
    debug_log "Found legacy major.minor version, padded to: $version"
  else
    # Enhanced fallback: try to extract version after any operator prefix, preserving v prefix
    version=$(echo "$version_string" | sed -E 's/^[a-zA-Z0-9][a-zA-Z0-9_-]*\.(v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9a-zA-Z._-]+)?).*$/\1/' | head -1)
    if [[ ! "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9a-zA-Z._-]+)?$ ]]; then
      # Final fallback: extract any version pattern, preserving v prefix
      version=$(echo "$version_string" | sed -E 's/.*\.(v?[0-9]+\.[0-9]+(\.[0-9]+)?(-[0-9a-zA-Z._-]+)?).*/\1/' | head -1)
    fi
    debug_log "Fallback extraction result: $version"
  fi
  
  # Normalize version for comparison (remove trailing parts after dash for comparison, preserve v prefix)
  local normalized_version
  if [[ "$version" =~ ^(v?[0-9]+\.[0-9]+\.[0-9]+)-.*\.(stable|fast|candidate|eus)$ ]]; then
    # Handle versions like v4.20.0-98.stable - extract base for comparison
    normalized_version="${BASH_REMATCH[1]}"
    debug_log "Normalized channel-specific version for comparison: $normalized_version (from $version)"
  elif [[ "$version" =~ ^(v?[0-9]+\.[0-9]+\.[0-9]+)-.*$ ]]; then
    normalized_version="${BASH_REMATCH[1]}"
    debug_log "Normalized version for comparison: $normalized_version (from $version)"
  else
    normalized_version="$version"
  fi
  
  # Enhanced validation - allow unlimited character suffixes and channel-specific versions with v prefix 
  if [[ "$normalized_version" =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || [[ "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+-[0-9a-zA-Z._-]+(\.(stable|fast|candidate|eus))?$ ]]; then
    echo "$version"  # Return the original version with extended info
    debug_log "Final version result: $version"
  else
    debug_log "Version validation failed, using fallback"
    echo "1.0.0"
  fi
}

version_compare() {
  # Enhanced version comparison for semantic versions and extended formats
  # Returns: 0 if equal, 1 if $1 > $2, 2 if $1 < $2
  local v1="$1" v2="$2"
  
  debug_log "Comparing versions: '$v1' vs '$v2'"
  
  # Normalize versions by extracting base semantic version for comparison
  local norm_v1 norm_v2
  
  # Extract base version (remove -XX.channel suffix for comparison, handle v prefix)
  if [[ "$v1" =~ ^(v?[0-9]+\.[0-9]+\.[0-9]+)-.*\.(stable|fast|candidate|eus)$ ]]; then
    norm_v1="${BASH_REMATCH[1]}"
  elif [[ "$v1" =~ ^(v?[0-9]+\.[0-9]+\.[0-9]+)-.*$ ]]; then
    norm_v1="${BASH_REMATCH[1]}"
  else
    norm_v1="$v1"
  fi
  
  if [[ "$v2" =~ ^(v?[0-9]+\.[0-9]+\.[0-9]+)-.*\.(stable|fast|candidate|eus)$ ]]; then
    norm_v2="${BASH_REMATCH[1]}"
  elif [[ "$v2" =~ ^(v?[0-9]+\.[0-9]+\.[0-9]+)-.*$ ]]; then
    norm_v2="${BASH_REMATCH[1]}"
  else
    norm_v2="$v2"
  fi
  
  # Remove 'v' prefix for numeric comparison
  norm_v1="${norm_v1#v}"
  norm_v2="${norm_v2#v}"
  
  debug_log "Normalized versions: '$norm_v1' vs '$norm_v2'"
  
  # Split versions into components
  IFS='.' read -ra V1 <<< "$norm_v1"
  IFS='.' read -ra V2 <<< "$norm_v2"
  
  # Pad arrays to same length
  local max_len=$((${#V1[@]} > ${#V2[@]} ? ${#V1[@]} : ${#V2[@]}))
  while [[ ${#V1[@]} -lt $max_len ]]; do V1+=("0"); done
  while [[ ${#V2[@]} -lt $max_len ]]; do V2+=("0"); done
  
  # Compare each component
  for ((i=0; i<max_len; i++)); do
    if [[ ${V1[i]} -gt ${V2[i]} ]]; then
      debug_log "Version comparison result: $v1 > $v2"
      return 1
    elif [[ ${V1[i]} -lt ${V2[i]} ]]; then
      debug_log "Version comparison result: $v1 < $v2"
      return 2
    fi
  done
  
  # If base versions are equal, compare the suffix numbers and channel types
  local suffix1="" suffix2="" channel1="" channel2=""
  
  # Extract suffix and channel from v1
  if [[ "$v1" =~ -([0-9]+)\.(stable|fast|candidate|eus)$ ]]; then
    suffix1="${BASH_REMATCH[1]}"
    channel1="${BASH_REMATCH[2]}"
  elif [[ "$v1" =~ -([0-9]+)$ ]]; then
    suffix1="${BASH_REMATCH[1]}"
  fi
  
  # Extract suffix and channel from v2
  if [[ "$v2" =~ -([0-9]+)\.(stable|fast|candidate|eus)$ ]]; then
    suffix2="${BASH_REMATCH[1]}"
    channel2="${BASH_REMATCH[2]}"
  elif [[ "$v2" =~ -([0-9]+)$ ]]; then
    suffix2="${BASH_REMATCH[1]}"
  fi
  
  # Compare suffixes if both versions have them
  if [[ -n "$suffix1" && -n "$suffix2" ]]; then
    if [[ "$suffix1" -gt "$suffix2" ]]; then
      debug_log "Version comparison result: $v1 > $v2 (by suffix: $suffix1 > $suffix2)"
      return 1
    elif [[ "$suffix1" -lt "$suffix2" ]]; then
      debug_log "Version comparison result: $v1 < $v2 (by suffix: $suffix1 < $suffix2)"
      return 2
    fi
    
    # If suffixes are equal, compare channels (stable > fast > candidate > eus is typical priority)
    if [[ -n "$channel1" && -n "$channel2" && "$channel1" != "$channel2" ]]; then
      case "$channel1-$channel2" in
        "stable-fast"|"stable-candidate"|"stable-eus"|"fast-candidate"|"fast-eus"|"candidate-eus")
          debug_log "Version comparison result: $v1 > $v2 (by channel: $channel1 > $channel2)"
          return 1
          ;;
        "fast-stable"|"candidate-stable"|"eus-stable"|"candidate-fast"|"eus-fast"|"eus-candidate")
          debug_log "Version comparison result: $v1 < $v2 (by channel: $channel1 < $channel2)"
          return 2
          ;;
      esac
    fi
  fi
  
  debug_log "Version comparison result: $v1 == $v2"
  return 0
}

find_min_max_versions() {
  local operator="$1"
  local default_channel="$2"
  
  debug_log "Finding min/max versions for $operator in channel $default_channel..."
  debug_log "No limitations mode: $NO_LIMITATIONS_MODE"
  debug_log "Channel-specific versions: $ALLOW_CHANNEL_SPECIFIC_VERSIONS"
  
  # Get detailed operator information including all channels
  local operator_details
  operator_details=$(retry 3 10 bash -c "
    oc-mirror list operators \
      --catalog \"$SOURCE_INDEX\" \
      --package \"$operator\" 2>/dev/null
  ")
  
  debug_log "Operator details output:"
  debug_log "$operator_details"
  
  # Extract versions from the specific default channel
  local versions_output
  versions_output=$(echo "$operator_details" | awk -v op="$operator" -v ch="$default_channel" '
    $1 == op && $2 == ch { print $3 }
  ')
  
  debug_log "Versions found in channel $default_channel: $versions_output"
  
  # If no limitations mode is enabled, get ALL versions from ALL channels
  if [[ "$NO_LIMITATIONS_MODE" == "true" ]]; then
    debug_log "No limitations mode: collecting ALL versions from ALL channels..."
    local all_versions
    all_versions=$(echo "$operator_details" | awk -v op="$operator" '
      NR > 1 && $1 == op && NF >= 3 { print $3 }
    ')
    if [[ -n "$all_versions" ]]; then
      versions_output="$versions_output"$'\n'"$all_versions"
    fi
    debug_log "Extended versions (all channels): $versions_output"
  # If no versions found in the specific channel, try to get all available versions
  elif [[ -z "$versions_output" ]]; then
    debug_log "No direct versions found in channel $default_channel, analyzing all versions..."
    versions_output=$(echo "$operator_details" | awk -v op="$operator" '
      NR > 1 && $1 == op && NF >= 3 { print $3 }
    ')
    debug_log "All versions found: $versions_output"
  fi
  
  if [[ -z "$versions_output" ]]; then
    debug_log "Warning: No versions found for $operator"
    echo "1.0.0 1.0.0"
    return
  fi
  
  local min_version="" max_version=""
  local versions_found=0
  local channel_specific_versions=()
  
  while IFS= read -r version_string; do
    [[ -z "$version_string" ]] && continue
    
    local version
    version=$(extract_version "$version_string")
    
    # Enhanced validation for channel-specific versions
    local is_valid=false
    if [[ "$ALLOW_CHANNEL_SPECIFIC_VERSIONS" == "true" ]]; then
      # Accept channel-specific versions like v4.20.0-98.stable or extended versions with unlimited suffixes
      if [[ "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9a-zA-Z._-]+)?(\.(stable|fast|candidate|eus))?$ ]]; then
        is_valid=true
        debug_log "Accepted channel-specific version: $version"
      fi
    else
      # Standard validation
      if [[ "$version" =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        is_valid=true
      fi
    fi
    
    if [[ "$is_valid" != "true" ]]; then
      debug_log "Skipping invalid version: $version_string -> $version"
      continue
    fi
    
    versions_found=$((versions_found + 1))
    debug_log "Found valid version: $version (from $version_string)"
    
    # Store channel-specific versions for special handling
    if [[ "$version" =~ -[0-9a-zA-Z._-]+(\.(stable|fast|candidate|eus))?$ ]]; then
      channel_specific_versions+=("$version")
    fi
    
    if [[ -z "$min_version" ]]; then
      min_version="$version"
      max_version="$version"
      debug_log "Initial version set: min=$min_version, max=$max_version"
    else
      # Check if this version is smaller than current min
      version_compare "$version" "$min_version"
      local cmp_result=$?
      if [[ $cmp_result -eq 2 ]]; then
        debug_log "New minimum: $version < $min_version"
        min_version="$version"
      fi
      
      # Check if this version is larger than current max
      version_compare "$version" "$max_version"
      cmp_result=$?
      if [[ $cmp_result -eq 1 ]]; then
        debug_log "New maximum: $version > $max_version"
        max_version="$version"
      fi
    fi
  done <<< "$versions_output"
  
  # Special handling for channel-specific versions
  if [[ "${#channel_specific_versions[@]}" -gt 0 ]]; then
    debug_log "Found ${#channel_specific_versions[@]} channel-specific versions"
    debug_log "Channel-specific versions: ${channel_specific_versions[*]}"
  fi
  
  # Fallback: get the latest version using channel-specific query
  if [[ $versions_found -eq 0 ]] || [[ -z "$min_version" || -z "$max_version" ]]; then
    debug_log "Using fallback method to get latest version..."
    local latest_version
    latest_version=$(retry 3 10 bash -c "
      oc-mirror list operators \
        --catalog \"$SOURCE_INDEX\" \
        --package \"$operator\" \
        --channel \"$default_channel\" 2>/dev/null | awk 'END {print \$3}'
    ")
    
    debug_log "Fallback latest version: $latest_version"
    
    if [[ -n "$latest_version" ]]; then
      local parsed_version
      parsed_version=$(extract_version "$latest_version")
      if [[ "$ALLOW_CHANNEL_SPECIFIC_VERSIONS" == "true" ]] && [[ "$parsed_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9a-zA-Z._-]+)?(\.(stable|fast|candidate|eus))?$ ]]; then
        min_version="$parsed_version"
        max_version="$parsed_version"
        debug_log "Fallback version set: $parsed_version"
      elif [[ "$parsed_version" =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        min_version="$parsed_version"
        max_version="$parsed_version"
        debug_log "Fallback version set: $parsed_version"
      fi
    fi
  fi
  
  # Final fallback
  if [[ -z "$min_version" || -z "$max_version" ]]; then
    min_version="1.0.0"
    max_version="1.0.0"
    debug_log "Warning: Could not determine versions, using fallback 1.0.0"
  fi
  
  debug_log "Final result: min=$min_version, max=$max_version"
  echo "$min_version $max_version"
}

# Test function for version parsing
test_version_parsing() {
  echo "Testing version parsing..."
  local test_cases=(
    "openshift-gitops-operator.v1.18.0:v1.18.0"
    "openshift-gitops-operator.v1.11.7-0.1724840231.p:v1.11.7-0.1724840231.p"
    "operator-name.v2.1.0-beta1:v2.1.0-beta1"
    "some-operator.v1.5:v1.5.0"
    "test.1.2.3:1.2.3"
    "odf-prometheus-operator.v4.20.0-98.stable:v4.20.0-98.stable"
    "odf-prometheus-operator.v4.20.0-98:v4.20.0-98"
    "some-operator.v3.15.2-45.candidate:v3.15.2-45.candidate"
    "operator.v2.8.1-12.fast:v2.8.1-12.fast"
    "odf-operator.v4.20.0-98.stable:v4.20.0-98.stable"
    "aap-operator.v2.5.0-0.1758147230:v2.5.0-0.1758147230"
    "aap-operator.v2.5.0-0.1758147817:v2.5.0-0.1758147817"
    "ansible-automation-platform-operator.v2.5.0-0.1758147230:v2.5.0-0.1758147230"
    "test-operator.v1.0.0-0.123456789012345:v1.0.0-0.123456789012345"
    "generic-operator.v3.2.1-0.987654321:v3.2.1-0.987654321"
    "some_operator.v2.4.6-0.1234567890abc:v2.4.6-0.1234567890abc"
    "operator-name.v1.0.0-0.deadbeef123:v1.0.0-0.deadbeef123"
    "my-operator.v4.20.0-99.stable:v4.20.0-99.stable"
  )
  
  for test_case in "${test_cases[@]}"; do
    IFS=':' read -r input expected <<< "$test_case"
    result=$(extract_version "$input")
    if [[ "$result" == "$expected" ]]; then
      echo "✅ PASS: $input -> $result"
    else
      echo "❌ FAIL: $input -> expected $expected, got $result"
    fi
  done
  echo "Version parsing tests completed."
}

# Test function for version comparison
test_version_comparison() {
  echo "Testing version comparison..."
  local test_cases=(
    "1.0.0:1.0.0:0"
    "1.1.0:1.0.0:1"
    "1.0.0:1.1.0:2"
    "2.0.0:1.9.9:1"
    "1.10.0:1.9.0:1"
    "1.0.1:1.0.0:1"
    "4.20.0-98:4.20.0-97:1"
    "4.20.0-97:4.20.0-98:2"
    "4.20.0-98:4.20.0-98:0"
    "4.21.0-1:4.20.0-99:1"
    "4.19.5-10:4.20.0-1:2"
    "4.20.0-98.stable:4.20.0-97.stable:1"
    "4.20.0-98.stable:4.20.0-98.fast:1"
    "4.20.0-98.stable:4.20.0-98.stable:0"
  )
  
  for test_case in "${test_cases[@]}"; do
    IFS=':' read -r v1 v2 expected <<< "$test_case"
    version_compare "$v1" "$v2"
    result=$?
    if [[ "$result" == "$expected" ]]; then
      echo "✅ PASS: $v1 vs $v2 -> $result"
    else
      echo "❌ FAIL: $v1 vs $v2 -> expected $expected, got $result"
    fi
  done
  echo "Version comparison tests completed."
}

# Function to generate templated imageset-config.yml
generate_imageset_config() {
  local ocp_version="${OCP_VERSION:-4.18.27}"
  local output_file="${IMAGESET_OUTPUT_FILE:-imageset-config.yml}"
  
  # Extract major.minor version (e.g., 4.18.27 -> 4.18)
  local major_minor
  if [[ "$ocp_version" =~ ^([0-9]+\.[0-9]+) ]]; then
    major_minor="${BASH_REMATCH[1]}"
  else
    echo "Error: Invalid OCP_VERSION format: $ocp_version. Expected format: X.Y.Z (e.g., 4.18.27)" >&2
    return 1
  fi
  
  # Set SOURCE_INDEX if not already set
  if [[ "$SOURCE_INDEX" == "<your_source_index_here>" ]] || [[ -z "$SOURCE_INDEX" ]]; then
    SOURCE_INDEX="registry.redhat.io/redhat/redhat-operator-index:v${major_minor}"
    debug_log "Setting SOURCE_INDEX to: $SOURCE_INDEX"
  fi
  
  debug_log "Generating imageset-config.yml with OCP_VERSION=$ocp_version, major.minor=$major_minor"
  debug_log "Using SOURCE_INDEX=$SOURCE_INDEX"
  
  # Pre-defined list of packages (from lines 18-40 of imageset-config.yml)
  local packages=(
    'advanced-cluster-management'
    'multicluster-engine'
    'topology-aware-lifecycle-manager'
    'openshift-gitops-operator'
    'lvms-operator'
    'odf-operator'
    'odf-dependencies'
    'rook-ceph-operator'
    'ocs-operator'
    'mcg-operator'
    'odf-prometheus-operator'
    'cephcsi-operator'
    'odf-csi-addons-operator'
    'ocs-client-operator'
    'recipe'
    'odf-csi-addons-operator'
    'local-storage-operator'
    'mcg-operator'
    'ptp-operator'
    'sriov-network-operator'
    'cluster-logging'
    'file-integrity-operator'
    'compliance-operator'
    'kernel-module-management'
    'kernel-module-management-hub'
    'node-maintenance-operator'
    'amq-streams'
    'quay-operator'
    'redhat-oadp-operator'
    'rhbk-operator'
    'lifecycle-agent'
    'metallb-operator'
  )
  
  echo "Fetching operator information and determining version ranges..."
  
  # Get default channels for each package
  local tmp_channels_file=$(mktemp)
  # Ensure cleanup on exit
  trap "rm -f '$tmp_channels_file'" EXIT
  
  retry 3 10 bash -c "
    oc-mirror list operators --catalog \"$SOURCE_INDEX\" 2>/dev/null \
    | awk 'x==1 {print \$1,\$NF} /NAME/ {x=1}' \
    > \"$tmp_channels_file\"
  " || {
    echo "Error: Failed to fetch operator information from catalog" >&2
    rm -f "$tmp_channels_file"
    return 1
  }
  
  # Generate the YAML file header
  cat > "$output_file" <<EOF
apiVersion: mirror.openshift.io/v2alpha1
kind: ImageSetConfiguration
archiveSize: 4
mirror:
  platform:
    architectures:
    - "amd64"
    channels:
    - name: stable-${major_minor}
      minVersion: ${ocp_version}
      maxVersion: ${ocp_version}
      type: ocp
    graph: true
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v${major_minor}
    full: false
    packages:
EOF
  
  # Process each package to get version ranges
  for pkg in "${packages[@]}"; do
    echo "Processing package: $pkg..."
    
    # Get default channel for this package
    local default_channel
    default_channel=$(awk -v pkg="$pkg" '$1 == pkg {print $2; exit}' "$tmp_channels_file")
    
    if [[ -z "$default_channel" ]]; then
      echo "Warning: Could not find default channel for $pkg, skipping version constraints" >&2
      echo "    - name: '${pkg}'" >> "$output_file"
      continue
    fi
    
    debug_log "Package: $pkg, Default channel: $default_channel"
    
    # Get min/max versions for this package
    local version_range
    version_range=$(find_min_max_versions "$pkg" "$default_channel")
    read -r min_version max_version <<< "$version_range"
    
    debug_log "Package: $pkg, Min version: $min_version, Max version: $max_version"
    
    # Check if this operator should skip channel and version constraints
    if should_skip_channel_and_versions "$pkg"; then
      debug_log "Skipping channel and version constraints for operator: $pkg"
      echo "    - name: '${pkg}'" >> "$output_file"
    # Check if this operator should skip version constraints (but keep channel)
    elif is_redhat_registry_operator "$pkg"; then
      debug_log "Skipping version constraints for Red Hat registry operator: $pkg"
      echo "    - name: '${pkg}'" >> "$output_file"
    else
      echo "    - name: '${pkg}'" >> "$output_file"
      echo "      channels:" >> "$output_file"
      echo "        - name: '${default_channel}'" >> "$output_file"
      echo "          minVersion: '${min_version}'" >> "$output_file"
      echo "          maxVersion: '${max_version}'" >> "$output_file"
    fi
  done
  
  # Clean up temp file
  rm -f "$tmp_channels_file"
  
  # Add additional images and helm sections
  cat >> "$output_file" <<EOF
  additionalImages:
  - name: registry.redhat.io/openshift4/ztp-site-generate-rhel8:v${major_minor}.0
  - name: registry.redhat.io/rhel9/support-tools:latest
  helm: {}
EOF
  
  echo "Generated $output_file with OCP_VERSION=$ocp_version (major.minor=$major_minor)"
  debug_log "Output file: $output_file"
}

# Help function
show_help() {
  cat << EOF
Enhanced ImageSet Configuration Generator

USAGE:
  $0 [OPTIONS]

OPTIONS:
  -h, --help              Show this help message
  -i, --index INDEX       Source catalog index (required)
  -o, --output FILE       Output ImageSet config file (default: imageset-config.yaml)
  -d, --debug             Enable debug mode
  -s, --single-version    Use single version mode (disable version ranges)
  -n, --no-limitations    Enable no limitations mode (include all versions from all channels)
  -c, --disable-channel-versions  Disable channel-specific version support
  -t, --test              Run version parsing tests and exit
  -g, --generate          Generate templated imageset-config.yml (requires OCP_VERSION)

ENVIRONMENT VARIABLES:
  SOURCE_INDEX                      Source catalog index
  IMAGESET_OUTPUT_FILE              Output file path
  DEBUG                             Enable debug mode (true/false)
  USE_VERSION_RANGE                 Enable version range detection (true/false)
  NO_LIMITATIONS_MODE               Enable no limitations mode (true/false)
  ALLOW_CHANNEL_SPECIFIC_VERSIONS   Allow channel-specific versions like v4.20.0-98.stable (true/false)
  OCP_VERSION                       OpenShift version (e.g., 4.18.27) for templating

EXAMPLES:
  # Basic usage
  $0 -i quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/catalog:v4.19

  # With debug and custom output
  $0 -i my-catalog:latest -o my-config.yaml -d

  # Enable no limitations mode (include all versions from all channels)
  $0 -i my-catalog:latest -n -d

  # With channel-specific versions like v4.20.0-98.stable (enabled by default)
  $0 -i my-catalog:latest -d

  # Disable channel-specific versions if you only want standard semantic versions
  $0 -i my-catalog:latest -c

  # Generate templated imageset-config.yml
  OCP_VERSION=4.18.27 $0 -g

  # Test version parsing
  $0 -t

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      show_help
      exit 0
      ;;
    -i|--index)
      SOURCE_INDEX="$2"
      shift 2
      ;;
    -o|--output)
      IMAGESET_OUTPUT_FILE="$2"
      shift 2
      ;;
    -d|--debug)
      DEBUG="true"
      shift
      ;;
    -s|--single-version)
      USE_VERSION_RANGE="false"
      shift
      ;;
    -n|--no-limitations)
      NO_LIMITATIONS_MODE="true"
      shift
      ;;
    -c|--disable-channel-versions)
      ALLOW_CHANNEL_SPECIFIC_VERSIONS="false"
      shift
      ;;
    -t|--test)
      test_version_parsing
      test_version_comparison
      exit 0
      ;;
    -g|--generate)
      generate_imageset_config
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Use -h or --help for usage information." >&2
      exit 1
      ;;
  esac
done

# Validate required parameters
if [[ "$SOURCE_INDEX" == "<your_source_index_here>" ]] || [[ -z "$SOURCE_INDEX" ]]; then
  echo "Error: SOURCE_INDEX is required. Use -i or set SOURCE_INDEX environment variable." >&2
  echo "Use -h or --help for usage information." >&2
  exit 1
fi

echo "Using SOURCE_INDEX=$SOURCE_INDEX"
echo "Using IMAGESET_OUTPUT_FILE=$IMAGESET_OUTPUT_FILE"
echo "Debug mode: $DEBUG"
echo "Use version range: $USE_VERSION_RANGE"
echo "No limitations mode: $NO_LIMITATIONS_MODE"
echo "Channel-specific versions: $ALLOW_CHANNEL_SPECIFIC_VERSIONS"

version_compare() {
  # Enhanced version comparison for semantic versions and extended formats
  # Returns: 0 if equal, 1 if $1 > $2, 2 if $1 < $2
  local v1="$1" v2="$2"
  
  debug_log "Comparing versions: '$v1' vs '$v2'"
  
  # Normalize versions by extracting base semantic version for comparison
  local norm_v1 norm_v2
  
  # Extract base version (remove -XX.channel suffix for comparison, handle v prefix)
  if [[ "$v1" =~ ^(v?[0-9]+\.[0-9]+\.[0-9]+)-.*\.(stable|fast|candidate|eus)$ ]]; then
    norm_v1="${BASH_REMATCH[1]}"
  elif [[ "$v1" =~ ^(v?[0-9]+\.[0-9]+\.[0-9]+)-.*$ ]]; then
    norm_v1="${BASH_REMATCH[1]}"
  else
    norm_v1="$v1"
  fi
  
  if [[ "$v2" =~ ^(v?[0-9]+\.[0-9]+\.[0-9]+)-.*\.(stable|fast|candidate|eus)$ ]]; then
    norm_v2="${BASH_REMATCH[1]}"
  elif [[ "$v2" =~ ^(v?[0-9]+\.[0-9]+\.[0-9]+)-.*$ ]]; then
    norm_v2="${BASH_REMATCH[1]}"
  else
    norm_v2="$v2"
  fi
  
  # Remove 'v' prefix for numeric comparison
  norm_v1="${norm_v1#v}"
  norm_v2="${norm_v2#v}"
  
  debug_log "Normalized versions: '$norm_v1' vs '$norm_v2'"
  
  # Split versions into components
  IFS='.' read -ra V1 <<< "$norm_v1"
  IFS='.' read -ra V2 <<< "$norm_v2"
  
  # Pad arrays to same length
  local max_len=$((${#V1[@]} > ${#V2[@]} ? ${#V1[@]} : ${#V2[@]}))
  while [[ ${#V1[@]} -lt $max_len ]]; do V1+=("0"); done
  while [[ ${#V2[@]} -lt $max_len ]]; do V2+=("0"); done
  
  # Compare each component
  for ((i=0; i<max_len; i++)); do
    if [[ ${V1[i]} -gt ${V2[i]} ]]; then
      debug_log "Version comparison result: $v1 > $v2"
      return 1
    elif [[ ${V1[i]} -lt ${V2[i]} ]]; then
      debug_log "Version comparison result: $v1 < $v2"
      return 2
    fi
  done
  
  # If base versions are equal, compare the suffix numbers and channel types
  local suffix1="" suffix2="" channel1="" channel2=""
  
  # Extract suffix and channel from v1
  if [[ "$v1" =~ -([0-9]+)\.(stable|fast|candidate|eus)$ ]]; then
    suffix1="${BASH_REMATCH[1]}"
    channel1="${BASH_REMATCH[2]}"
  elif [[ "$v1" =~ -([0-9]+)$ ]]; then
    suffix1="${BASH_REMATCH[1]}"
  fi
  
  # Extract suffix and channel from v2
  if [[ "$v2" =~ -([0-9]+)\.(stable|fast|candidate|eus)$ ]]; then
    suffix2="${BASH_REMATCH[1]}"
    channel2="${BASH_REMATCH[2]}"
  elif [[ "$v2" =~ -([0-9]+)$ ]]; then
    suffix2="${BASH_REMATCH[1]}"
  fi
  
  # Compare suffixes if both versions have them
  if [[ -n "$suffix1" && -n "$suffix2" ]]; then
    if [[ "$suffix1" -gt "$suffix2" ]]; then
      debug_log "Version comparison result: $v1 > $v2 (by suffix: $suffix1 > $suffix2)"
      return 1
    elif [[ "$suffix1" -lt "$suffix2" ]]; then
      debug_log "Version comparison result: $v1 < $v2 (by suffix: $suffix1 < $suffix2)"
      return 2
    fi
    
    # If suffixes are equal, compare channels (stable > fast > candidate > eus is typical priority)
    if [[ -n "$channel1" && -n "$channel2" && "$channel1" != "$channel2" ]]; then
      case "$channel1-$channel2" in
        "stable-fast"|"stable-candidate"|"stable-eus"|"fast-candidate"|"fast-eus"|"candidate-eus")
          debug_log "Version comparison result: $v1 > $v2 (by channel: $channel1 > $channel2)"
          return 1
          ;;
        "fast-stable"|"candidate-stable"|"eus-stable"|"candidate-fast"|"eus-fast"|"eus-candidate")
          debug_log "Version comparison result: $v1 < $v2 (by channel: $channel1 < $channel2)"
          return 2
          ;;
      esac
    fi
  fi
  
  debug_log "Version comparison result: $v1 == $v2"
  return 0
}

find_min_max_versions() {
  local operator="$1"
  local default_channel="$2"
  
  debug_log "Finding min/max versions for $operator in channel $default_channel..."
  debug_log "No limitations mode: $NO_LIMITATIONS_MODE"
  debug_log "Channel-specific versions: $ALLOW_CHANNEL_SPECIFIC_VERSIONS"
  
  # Get detailed operator information including all channels
  local operator_details
  operator_details=$(retry 3 10 bash -c "
    oc-mirror list operators \
      --catalog \"$SOURCE_INDEX\" \
      --package \"$operator\" 2>/dev/null
  ")
  
  debug_log "Operator details output:"
  debug_log "$operator_details"
  
  # Extract versions from the specific default channel
  local versions_output
  versions_output=$(echo "$operator_details" | awk -v op="$operator" -v ch="$default_channel" '
    $1 == op && $2 == ch { print $3 }
  ')
  
  debug_log "Versions found in channel $default_channel: $versions_output"
  
  # If no limitations mode is enabled, get ALL versions from ALL channels
  if [[ "$NO_LIMITATIONS_MODE" == "true" ]]; then
    debug_log "No limitations mode: collecting ALL versions from ALL channels..."
    local all_versions
    all_versions=$(echo "$operator_details" | awk -v op="$operator" '
      NR > 1 && $1 == op && NF >= 3 { print $3 }
    ')
    if [[ -n "$all_versions" ]]; then
      versions_output="$versions_output"$'\n'"$all_versions"
    fi
    debug_log "Extended versions (all channels): $versions_output"
  # If no versions found in the specific channel, try to get all available versions
  elif [[ -z "$versions_output" ]]; then
    debug_log "No direct versions found in channel $default_channel, analyzing all versions..."
    versions_output=$(echo "$operator_details" | awk -v op="$operator" '
      NR > 1 && $1 == op && NF >= 3 { print $3 }
    ')
    debug_log "All versions found: $versions_output"
  fi
  
  if [[ -z "$versions_output" ]]; then
    debug_log "Warning: No versions found for $operator"
    echo "1.0.0 1.0.0"
    return
  fi
  
  local min_version="" max_version=""
  local versions_found=0
  local channel_specific_versions=()
  
  while IFS= read -r version_string; do
    [[ -z "$version_string" ]] && continue
    
    local version
    version=$(extract_version "$version_string")
    
    # Enhanced validation for channel-specific versions
    local is_valid=false
    if [[ "$ALLOW_CHANNEL_SPECIFIC_VERSIONS" == "true" ]]; then
      # Accept channel-specific versions like v4.20.0-98.stable or extended versions with unlimited suffixes
      if [[ "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9a-zA-Z._-]+)?(\.(stable|fast|candidate|eus))?$ ]]; then
        is_valid=true
        debug_log "Accepted channel-specific version: $version"
      fi
    else
      # Standard validation
      if [[ "$version" =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        is_valid=true
      fi
    fi
    
    if [[ "$is_valid" != "true" ]]; then
      debug_log "Skipping invalid version: $version_string -> $version"
      continue
    fi
    
    versions_found=$((versions_found + 1))
    debug_log "Found valid version: $version (from $version_string)"
    
    # Store channel-specific versions for special handling
    if [[ "$version" =~ -[0-9a-zA-Z._-]+(\.(stable|fast|candidate|eus))?$ ]]; then
      channel_specific_versions+=("$version")
    fi
    
    if [[ -z "$min_version" ]]; then
      min_version="$version"
      max_version="$version"
      debug_log "Initial version set: min=$min_version, max=$max_version"
    else
      # Check if this version is smaller than current min
      version_compare "$version" "$min_version"
      local cmp_result=$?
      if [[ $cmp_result -eq 2 ]]; then
        debug_log "New minimum: $version < $min_version"
        min_version="$version"
      fi
      
      # Check if this version is larger than current max
      version_compare "$version" "$max_version"
      cmp_result=$?
      if [[ $cmp_result -eq 1 ]]; then
        debug_log "New maximum: $version > $max_version"
        max_version="$version"
      fi
    fi
  done <<< "$versions_output"
  
  # Special handling for channel-specific versions
  if [[ "${#channel_specific_versions[@]}" -gt 0 ]]; then
    debug_log "Found ${#channel_specific_versions[@]} channel-specific versions"
    debug_log "Channel-specific versions: ${channel_specific_versions[*]}"
  fi
  
  # Fallback: get the latest version using channel-specific query
  if [[ $versions_found -eq 0 ]] || [[ -z "$min_version" || -z "$max_version" ]]; then
    debug_log "Using fallback method to get latest version..."
    local latest_version
    latest_version=$(retry 3 10 bash -c "
      oc-mirror list operators \
        --catalog \"$SOURCE_INDEX\" \
        --package \"$operator\" \
        --channel \"$default_channel\" 2>/dev/null | awk 'END {print \$3}'
    ")
    
    debug_log "Fallback latest version: $latest_version"
    
    if [[ -n "$latest_version" ]]; then
      local parsed_version
      parsed_version=$(extract_version "$latest_version")
      if [[ "$ALLOW_CHANNEL_SPECIFIC_VERSIONS" == "true" ]] && [[ "$parsed_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9a-zA-Z._-]+)?(\.(stable|fast|candidate|eus))?$ ]]; then
        min_version="$parsed_version"
        max_version="$parsed_version"
        debug_log "Fallback version set: $parsed_version"
      elif [[ "$parsed_version" =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        min_version="$parsed_version"
        max_version="$parsed_version"
        debug_log "Fallback version set: $parsed_version"
      fi
    fi
  fi
  
  # Final fallback
  if [[ -z "$min_version" || -z "$max_version" ]]; then
    min_version="1.0.0"
    max_version="1.0.0"
    debug_log "Warning: Could not determine versions, using fallback 1.0.0"
  fi
  
  debug_log "Final result: min=$min_version, max=$max_version"
  echo "$min_version $max_version"
}

# Test function for version parsing
test_version_parsing() {
  echo "Testing version parsing..."
  local test_cases=(
    "openshift-gitops-operator.v1.18.0:v1.18.0"
    "openshift-gitops-operator.v1.11.7-0.1724840231.p:v1.11.7-0.1724840231.p"
    "operator-name.v2.1.0-beta1:v2.1.0-beta1"
    "some-operator.v1.5:v1.5.0"
    "test.1.2.3:1.2.3"
    "odf-prometheus-operator.v4.20.0-98.stable:v4.20.0-98.stable"
    "odf-prometheus-operator.v4.20.0-98:v4.20.0-98"
    "some-operator.v3.15.2-45.candidate:v3.15.2-45.candidate"
    "operator.v2.8.1-12.fast:v2.8.1-12.fast"
    "odf-operator.v4.20.0-98.stable:v4.20.0-98.stable"
    "aap-operator.v2.5.0-0.1758147230:v2.5.0-0.1758147230"
    "aap-operator.v2.5.0-0.1758147817:v2.5.0-0.1758147817"
    "ansible-automation-platform-operator.v2.5.0-0.1758147230:v2.5.0-0.1758147230"
    "test-operator.v1.0.0-0.123456789012345:v1.0.0-0.123456789012345"
    "generic-operator.v3.2.1-0.987654321:v3.2.1-0.987654321"
    "some_operator.v2.4.6-0.1234567890abc:v2.4.6-0.1234567890abc"
    "operator-name.v1.0.0-0.deadbeef123:v1.0.0-0.deadbeef123"
    "my-operator.v4.20.0-99.stable:v4.20.0-99.stable"
  )
  
  for test_case in "${test_cases[@]}"; do
    IFS=':' read -r input expected <<< "$test_case"
    result=$(extract_version "$input")
    if [[ "$result" == "$expected" ]]; then
      echo "✅ PASS: $input -> $result"
    else
      echo "❌ FAIL: $input -> expected $expected, got $result"
    fi
  done
  echo "Version parsing tests completed."
}

# Test function for version comparison
test_version_comparison() {
  echo "Testing version comparison..."
  local test_cases=(
    "1.0.0:1.0.0:0"
    "1.1.0:1.0.0:1"
    "1.0.0:1.1.0:2"
    "2.0.0:1.9.9:1"
    "1.10.0:1.9.0:1"
    "1.0.1:1.0.0:1"
    "4.20.0-98:4.20.0-97:1"
    "4.20.0-97:4.20.0-98:2"
    "4.20.0-98:4.20.0-98:0"
    "4.21.0-1:4.20.0-99:1"
    "4.19.5-10:4.20.0-1:2"
    "4.20.0-98.stable:4.20.0-97.stable:1"
    "4.20.0-98.stable:4.20.0-98.fast:1"
    "4.20.0-98.stable:4.20.0-98.stable:0"
  )
  
  for test_case in "${test_cases[@]}"; do
    IFS=':' read -r v1 v2 expected <<< "$test_case"
    version_compare "$v1" "$v2"
    result=$?
    if [[ "$result" == "$expected" ]]; then
      echo "✅ PASS: $v1 vs $v2 -> $result"
    else
      echo "❌ FAIL: $v1 vs $v2 -> expected $expected, got $result"
    fi
  done
  echo "Version comparison tests completed."
}

# --- Get operators and their default channels ---
echo "Fetching operators and default channels..."
retry 3 10 bash -c "
  oc-mirror list operators --catalog \"$SOURCE_INDEX\" 2>/dev/null \
  | awk 'x==1 {print \$1,\$NF} /NAME/ {x=1}' \
  > \"$TMPDIR/operators.txt\"
"

mapfile -t OPERATORS < <(awk '{print $1}' "$TMPDIR/operators.txt")
mapfile -t DEF_CHANNELS < <(awk '{print $2}' "$TMPDIR/operators.txt")

# --- Get versions for each operator/channel ---
if [[ "$USE_VERSION_RANGE" == "true" ]]; then
  echo "Determining dynamic version ranges for operators..."
  MIN_VERSIONS=()
  MAX_VERSIONS=()

  for i in "${!OPERATORS[@]}"; do
    OP="${OPERATORS[$i]}"
    CH="${DEF_CHANNELS[$i]}"
    echo "Analyzing versions for operator=$OP channel=$CH..."
    debug_log "Processing operator: $OP, channel: $CH"

    # Get min/max versions dynamically
    version_range=$(find_min_max_versions "$OP" "$CH")
    read -r min_ver max_ver <<< "$version_range"
    
    MIN_VERSIONS+=("$min_ver")
    MAX_VERSIONS+=("$max_ver")
    
    echo "  -> Min version: $min_ver, Max version: $max_ver"
    debug_log "Version range for $OP: $min_ver to $max_ver"
  done
else
  echo "Using single version mode (original behavior)..."
  DEF_PACKAGES=()
  for i in "${!OPERATORS[@]}"; do
    OP="${OPERATORS[$i]}"
    CH="${DEF_CHANNELS[$i]}"
    echo "Fetching default CSV for operator=$OP channel=$CH..."
    debug_log "Getting single version for $OP in channel $CH"

    pkg=$(retry 3 10 bash -c "
      oc-mirror list operators \
        --catalog \"$SOURCE_INDEX\" \
        --package \"$OP\" \
        --channel \"$CH\" 2>/dev/null | tail -1 | awk '{print \$3}'
    ")
    
    # Extract version from package string
    version=$(extract_version "$pkg")
    DEF_PACKAGES+=("$version")
    debug_log "Single version for $OP: $version (from $pkg)"
  done
fi

# --- Render packages list into YAML ---
if [[ "$USE_VERSION_RANGE" == "true" ]]; then
  echo "Rendering packages list with dynamic version ranges..."
  {
    for i in "${!OPERATORS[@]}"; do
      echo "- name: '${OPERATORS[$i]}'"
      
      # Check if this operator should skip channel and version constraints
      if should_skip_channel_and_versions "${OPERATORS[$i]}"; then
        debug_log "Skipping channel and version constraints for operator: ${OPERATORS[$i]}"
      else
        echo "  channels:"
        echo "    - name: '${DEF_CHANNELS[$i]}'"
        
        # Skip version constraints for Red Hat registry operators
        if is_redhat_registry_operator "${OPERATORS[$i]}"; then
          debug_log "Skipping version constraints for Red Hat registry operator: ${OPERATORS[$i]}"
        else
          echo "      minVersion: '${MIN_VERSIONS[$i]}'"
          echo "      maxVersion: '${MAX_VERSIONS[$i]}'"
        fi
      fi
    done
  } > "$TMPDIR/packages.yaml"
else
  echo "Rendering packages list with single versions..."
  {
    for i in "${!OPERATORS[@]}"; do
      echo "- name: '${OPERATORS[$i]}'"
      
      # Check if this operator should skip channel and version constraints
      if should_skip_channel_and_versions "${OPERATORS[$i]}"; then
        debug_log "Skipping channel and version constraints for operator: ${OPERATORS[$i]}"
      else
        echo "  channels:"
        echo "    - name: '${DEF_CHANNELS[$i]}'"
        
        # Skip version constraints for Red Hat registry operators
        if is_redhat_registry_operator "${OPERATORS[$i]}"; then
          debug_log "Skipping version constraints for Red Hat registry operator: ${OPERATORS[$i]}"
        else
          echo "      minVersion: '${DEF_PACKAGES[$i]}'"
          echo "      maxVersion: '${DEF_PACKAGES[$i]}'"
        fi
      fi
    done
  } > "$TMPDIR/packages.yaml"
fi

# --- Render ImageSetConfiguration ---
echo "Creating ImageSetConfiguration..."
cat > "$IMAGESET_OUTPUT_FILE" <<EOF
apiVersion: mirror.openshift.io/v2alpha1
kind: ImageSetConfiguration
mirror:
  operators:
    - catalog: $SOURCE_INDEX
      packages:
$(sed 's/^/        /' "$TMPDIR/packages.yaml")
EOF

echo "ImageSetConfiguration written to ${IMAGESET_OUTPUT_FILE}"
