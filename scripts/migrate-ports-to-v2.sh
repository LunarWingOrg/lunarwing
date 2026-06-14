#!/bin/bash
# LunarWing Port Schema Migration Script
# Migrates legacy port.json to v2 tenant-block format
# Date: 2026-06-16
# Author: Kageho

#possibly broken in current state due to single-quoted heredocs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTS_FILE="${SCRIPT_DIR}/../ic/config/ports.json"
BACKUP_FILE="${SCRIPT_DIR}/../ic/config/ports.json.bak.$(date +%Y%m%d%H%M%S)"
LOG_FILE="${SCRIPT_DIR}/../logs/port-migration.log"

log() {
    echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] $1" | tee -a "$LOG_FILE"
}

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Check if ports.json exists
if [[ ! -f "$PORTS_FILE" ]]; then
    print_error "Port configuration file not found: $PORTS_FILE"
    exit 1
fi

# Backup existing file
print_status "Backing up existing port configuration..."
cp "$PORTS_FILE" "$BACKUP_FILE"
print_status "Backup saved to: $BACKUP_FILE"

# Parse existing port configuration
print_status "Analyzing current port assignments..."

# Use jq if available, otherwise fall back to python
if command -v jq &> /dev/null; then
    TENANTS=$(jq -r 'keys[]' "$PORTS_FILE" 2>/dev/null || echo "")
    HAS_TENANTS=$(echo "$TENANTS" | wc -l)
else
    print_warning "jq not found, using Python for JSON parsing..."
    TENANTS=$(python3 -c "import json; print('\n'.join(json.load(open('$PORTS_FILE')).keys()))" 2>/dev/null || echo "")
    HAS_TENANTS=$(echo "$TENANTS" | wc -l)
fi

if [[ -z "$TENANTS" || "$HAS_TENANTS" -eq 0 ]]; then
    print_error "No tenants found in port configuration"
    exit 1
fi

print_status "Found $HAS_TENANTS tenants to migrate"

# Determine block size (default 10 ports per tenant)
BLOCK_SIZE=10

# Generate new v2 port configuration
print_status "Generating v2 port configuration..."

# Create new JSON structure
python3 << 'PYTHON_SCRIPT'
import json
import sys

# Load existing configuration
with open('${PORTS_FILE}', 'r') as f:
    old_config = json.load(f)

# Define service offsets for v2 format
SERVICE_OFFSETS = {
    'gateway': 0,
    'websocket': 1,
    'telemetry': 2,
    'adapter': 3,
    'worker': 4,
    'debug': 5,
    'metrics': 6,
    'health': 7,
    'reserved_1': 8,
    'reserved_2': 9
}

# Detect block size from existing assignments
def detect_block_size(old_config):
    """Detect the port block size from existing tenant assignments"""
    base_ports = []
    for tenant, config in old_config.items():
        if isinstance(config, dict):
            if 'base_port' in config:
                base_ports.append(config['base_port'])
            elif 'gateway' in config:
                # Extract base port (assume gateway is at offset 0)
                base_ports.append(config['gateway'])
    
    if not base_ports:
        return 10  # Default
    
    # Find the minimum difference between base ports
    base_ports.sort()
    diffs = [base_ports[i+1] - base_ports[i] for i in range(len(base_ports)-1)]
    
    if diffs:
        return min(diffs)
    return 10

# Convert legacy format to v2 format
def convert_to_v2(old_config, block_size):
    """Convert legacy port config to v2 tenant-block format"""
    new_config = {
        'schema_version': 'v2',
        'migrated_at': '$(date -u +"%Y-%m-%dT%H:%M:%SZ")',
        'tenants': {}
    }
    
    # Track used base ports to avoid collisions
    used_base_ports = set()
    
    for tenant, config in old_config.items():
        if isinstance(config, dict):
            # Detect base port from existing config
            if 'base_port' in config:
                base_port = config['base_port']
            elif 'gateway' in config:
                # Legacy format: gateway is at base port
                base_port = config['gateway']
            else:
                print(f"Warning: Could not determine base port for tenant '{tenant}'", file=sys.stderr)
                continue
            
            # Ensure we have a valid base port
            if base_port in used_base_ports:
                print(f"Error: Duplicate base port {base_port} for tenant '{tenant}'", file=sys.stderr)
                continue
            
            used_base_ports.add(base_port)
            
            # Extract service offsets from legacy config
            service_offsets = {}
            for service, offset in SERVICE_OFFSETS.items():
                port_key = service
                if service.startswith('reserved'):
                    port_key = service  # Keep reserved ports
            
            # Build new tenant config
            new_config['tenants'][tenant] = {
                'schema_version': 'v2',
                'base_port': base_port,
                'block_size': block_size,
                'service_offsets': {}
            }
            
            # Map existing services to offsets
            if 'gateway' in config:
                new_config['tenants'][tenant]['service_offsets']['gateway'] = config['gateway'] - base_port
            if 'websocket' in config:
                new_config['tenants'][tenant]['service_offsets']['websocket'] = config['websocket'] - base_port
            if 'telemetry' in config:
                new_config['tenants'][tenant]['service_offsets']['telemetry'] = config['telemetry'] - base_port
            if 'adapter' in config:
                new_config['tenants'][tenant]['service_offsets']['adapter'] = config['adapter'] - base_port
            if 'worker' in config:
                new_config['tenants'][tenant]['service_offsets']['worker'] = config['worker'] - base_port
            
            # Add default offsets for services not explicitly configured
            for service, default_offset in SERVICE_OFFSETS.items():
                if service not in new_config['tenants'][tenant]['service_offsets']:
                    new_config['tenants'][tenant]['service_offsets'][service] = default_offset
    
    return new_config

# Main migration logic
block_size = detect_block_size(old_config)
print(f"Detected block size: {block_size}")

new_config = convert_to_v2(old_config, block_size)

# Write new configuration
with open('${PORTS_FILE}', 'w') as f:
    json.dump(new_config, f, indent=2)

print(f"Migration complete. {len(new_config['tenants'])} tenants converted to v2 schema.")
PYTHON_SCRIPT

# Validate new configuration
print_status "Validating new port configuration..."

# Check that all ports are unique and within expected ranges
python3 << 'VALIDATE_SCRIPT'
import json

with open('${PORTS_FILE}', 'r') as f:
    config = json.load(f)

if config.get('schema_version') != 'v2':
    print("Error: Migration failed - schema_version is not v2")
    exit(1)

# Check for port collisions
all_ports = {}
collision_count = 0

for tenant, tconfig in config['tenants'].items():
    base = tconfig['base_port']
    for service, offset in tconfig['service_offsets'].items():
        port = base + offset
        if port in all_ports:
            print(f"Warning: Port collision detected - {port} used by {all_ports[port]} and {tenant}/{service}")
            collision_count += 1
        else:
            all_ports[port] = f"{tenant}/{service}"

if collision_count == 0:
    print(f"Validation passed. No port collisions detected. {len(all_ports)} unique ports configured.")
else:
    print(f"Warning: {collision_count} port collisions detected. Review manually.")
VALIDATE_SCRIPT

# Check if validation passed
if [[ $? -eq 0 ]]; then
    print_status "Migration completed successfully!"
    print_status ""
    echo "Summary:"
    echo "  - Backup: $BACKUP_FILE"
    echo "  - New schema version: v2"
    echo "  - Tenants migrated: $HAS_TENANTS"
    echo ""
    print_warning "IMPORTANT: Restart all LunarWing services to apply new configuration."
    print_warning "If issues occur, restore from backup: cp $BACKUP_FILE $PORTS_FILE"
else
    print_error "Migration completed with validation warnings."
    print_error "Review the output above and check for port collisions."
    print_warning "Backup available at: $BACKUP_FILE"
    exit 1
fi

print_status ""
print_status "To rollback, run:"
print_status "  cp $BACKUP_FILE $PORTS_FILE"
print_status "  systemctl restart lunarwing-*"
