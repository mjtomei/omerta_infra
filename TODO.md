# Omerta Infrastructure TODO

## Backup Systems (Planned)

### Infrastructure Redundancy
- Multi-region deployment (us-west-2 + us-east-1)
- Failover DNS with Route53 health checks
- Cross-region snapshot replication

### Attestation Data Export
- S3 bucket for attestation data backups
- Scheduled export from bootstrap nodes
- Versioning and lifecycle policies for retention

### Key Material Backup
- Secure backup of bootstrap node signing keys
- AWS Secrets Manager or KMS integration
- Recovery procedures documentation

## Data Persistence

### Network State Protection
When attestations and peer reputation are added, consider migrating from JSON files to SQLite with WAL mode for:
- ACID transactions with automatic rollback
- Protection against partial writes
- Audit trail of changes

Current storage locations:
- `~/.omerta/OmertaMesh/networks.json` - Network memberships
- `~/.omerta/config.json` - Network keys

Short-term: Add backup rotation before writes
Long-term: SQLite database with proper schema

## Identity System

### Peer ID Security Fix
The CLI `--peer-id` flag allows arbitrary peer IDs disconnected from cryptographic identity. This should be fixed so peer IDs are derived from public keys (like OmertaCore does) to prevent impersonation.

See: `omerta_mesh/Sources/OmertaMesh/MeshNode.swift` lines 163-166
