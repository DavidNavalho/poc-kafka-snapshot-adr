# Phase 6 Walkthrough (Kafka ACL metadata continuity)

Goal:
- validate ACL metadata survives snapshot-copy restore in KRaft
- keep data + consumer-group parity checks so ACL-only restore is not isolated from functional behavior

## Topics and groups

Topics:
- `dr.p6.secure.orders` (delete, 4 partitions, 700 records)
- `dr.p6.secure.audit` (delete, 3 partitions, 500 records)
- `dr.p6.secure.state` (compact, 4 partitions, 650 records)

Groups:
- full: `dr.phase6.group.full`
- partial: `dr.phase6.group.partial`

## ACL set applied on source

Principals:
- producer: `User:app-producer`
- full consumer: `User:app-consumer-full`
- partial consumer: `User:app-consumer-partial`
- admin: `User:ops-admin`
- deny actor: `User:bad-actor`

Rules created:
1. allow `Write`, `Describe` on `dr.p6.secure.orders` for producer principal
2. allow `Read`, `Describe` on `dr.p6.secure.orders` for full consumer principal
3. allow `Read` on group `dr.phase6.group.full` for full consumer principal
4. allow `Read` on prefixed topic `dr.p6.secure.` for partial consumer principal
5. allow `Read` on group `dr.phase6.group.partial` for partial consumer principal
6. allow `Alter`, `Describe` on cluster for admin principal
7. deny `Delete` on `dr.p6.secure.orders` for deny principal

## Run command

```bash
scripts/harness/run_phase6.sh
```

Order:
1. `reset_lab.sh`
2. `start_source.sh`
3. `seed_source_phase6.sh`
4. `snapshot_copy_to_target.sh`
5. `start_target.sh`
6. `validate_target_phase6.sh`

## Source capture

Captured artifacts:
- topic data/offset/hash files:
  - `artifacts/latest/source/phase6/topics/<topic>/...`
- group offsets:
  - `artifacts/latest/source/phase6/groups/<group>.offsets.txt`
- ACLs:
  - raw: `artifacts/latest/source/phase6/acls/acls.list.raw.txt`
  - normalized (sorted): `artifacts/latest/source/phase6/acls/acls.list.normalized.txt`

## Target validation

1. `cluster.id` parity
2. per-topic end-offset and payload-hash parity
3. group offset parity at snapshot point (full + partial)
4. partial group resumes and advances offsets post-restore
5. ACL metadata parity:
   - compare normalized source ACL list vs target ACL list
   - verify all expected principal/topic/group markers exist

## Notes

- Cluster runs with KRaft `StandardAuthorizer`.
- Lab keeps `allow.everyone.if.no.acl.found=true` and `super.users=User:ANONYMOUS` for low-friction testing of metadata continuity rather than auth enforcement.
