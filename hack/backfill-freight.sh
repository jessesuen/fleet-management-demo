#!/usr/bin/env bash
#
# Creates Freight for the older artifact versions a Warehouse has already discovered, so the Freight
# timeline has history to promote and roll back through. Kargo itself only creates Freight for the
# newest version.
#
# Usage:
#   hack/backfill-freight.sh <project> [<warehouse>...]
#
# With no Warehouses, backfills every Warehouse in the project.
#
# Environment:
#   LIMIT    Max Freight to create per Warehouse, newest first (default: all discovered versions)
#   DRY_RUN  If "true", print the Freight manifests instead of creating them
#
# Each Freight is stamped with its artifact's creation time (image createdAt, commit creatorDate) as
# discoveredAt, which is what the timeline sorts by. Versions without a timestamp (charts), or with
# the same one as a newer version, are spaced a minute apart.
#
# A Warehouse with several subscriptions gets one Freight per version of its first subscription,
# paired with the newest version of each of the others.
set -euo pipefail

PROJECT="${1:?usage: $0 <project> [<warehouse>...]}"
shift
LIMIT="${LIMIT:-0}"
DRY_RUN="${DRY_RUN:-false}"

# kargo get prints one object for a single result, and a list otherwise
items() { jq -c 'if type == "array" then .[] elif has("items") then .items[] else . end'; }

warehouses=("$@")
if [[ ${#warehouses[@]} -eq 0 ]]; then
  while read -r w; do warehouses+=("$w"); done < <(
    kargo get warehouses --project "$PROJECT" -o json | items | jq -r '.metadata.name'
  )
fi

# Identifies a Freight by its artifacts, to skip versions that already have Freight
read -r -d '' ARTIFACT_KEY <<'EOF' || true
def artifactKey:
  [ (.images // [])[] | "image:\(.repoURL)@\(.digest // .tag)" ] +
  [ (.charts // [])[] | "chart:\(.repoURL)/\(.name // "")@\(.version)" ] +
  [ (.commits // [])[] | "git:\(.repoURL)@\(.id)" ]
  | sort | join(",");
EOF

# Builds one Freight per discovered version of the first subscription, oldest first
read -r -d '' BUILD <<'EOF' || true
.metadata.name as $warehouse
| .status.discoveredArtifacts as $d
| ($d.discoveredAt | sub("\\.[0-9]+"; "") | fromdateiso8601) as $now
| [ ($d.images // [])[] | {kind: "image", sub: .} ] +
  [ ($d.charts // [])[] | {kind: "chart", sub: .} ] +
  [ ($d.git // [])[]    | {kind: "git",   sub: .} ]
| . as $subs
| if length == 0 then empty else
  def versions($s):
    if $s.kind == "image" then
      [ $s.sub.references[] | {
          artifact: {repoURL: $s.sub.repoURL, tag, digest, annotations, subscriptionName: $s.sub.subscriptionName},
          at: .createdAt } ]
    elif $s.kind == "chart" then
      [ $s.sub.versions[] | {
          artifact: {repoURL: $s.sub.repoURL, name: $s.sub.name, version: ., subscriptionName: $s.sub.subscriptionName},
          at: null } ]
    else
      [ $s.sub.commits[] | {
          artifact: {repoURL: $s.sub.repoURL, id, branch, tag, message: .subject, author, committer,
                     subscriptionName: $s.sub.subscriptionName},
          at: .creatorDate } ]
    end
    | map(.artifact |= with_entries(select(.value != null and .value != "")));
  def field($kind): {image: "images", chart: "charts", git: "commits"}[$kind];
  # Newest first. Registries often report the same creation time for several tags, so keep the
  # times strictly decreasing, a minute apart where they'd tie, so the timeline order is stable.
  versions($subs[0]) as $all
  | reduce range(0; $all | length) as $i ([];
      ($all[$i].at | if . then sub("\\.[0-9]+"; "") | fromdateiso8601 else null end) as $t
      | . + [$all[$i] + {t: (if $i == 0 then ($t // $now) else ([$t // infinite, .[-1].t - 60] | min) end)}])
  | (if $limit > 0 then .[:$limit] else . end)
  | reverse[]
  | . as $v
  | (reduce ($subs[1:][] | {f: field(.kind), a: versions(.)[0].artifact}) as $o
      ({(field($subs[0].kind)): [$v.artifact]}; .[$o.f] += [$o.a])) as $artifacts
  | {
      apiVersion: "kargo.akuity.io/v1alpha1",
      kind: "Freight",
      # Placeholder; Kargo replaces it with the ID it computes from the artifacts
      metadata: {name: "backfill", namespace: $project},
      origin: {kind: "Warehouse", name: $warehouse},
      discoveredAt: ($v.t | todateiso8601)
    } + $artifacts
  end
EOF

for w in "${warehouses[@]}"; do
  warehouse=$(kargo get warehouse "$w" --project "$PROJECT" -o json)
  existing=$(kargo get freight --project "$PROJECT" --warehouse "$w" -o json 2>/dev/null \
    | items | jq -r "$ARTIFACT_KEY artifactKey" || true)

  created=0 skipped=0
  while read -r freight; do
    [[ -z "$freight" ]] && continue
    key=$(jq -r "$ARTIFACT_KEY artifactKey" <<<"$freight")
    version=$(jq -r '[(.images // [])[0].tag, (.charts // [])[0].version, (.commits // [])[0].id] | map(select(.)) | first' <<<"$freight")
    if grep -qxF "$key" <<<"$existing"; then
      skipped=$((skipped + 1))
      continue
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "---"
      yq -P <<<"$freight"
    else
      if out=$(kargo create -f - <<<"$freight" 2>&1); then
        echo "$w: created Freight for $version"
        # creationTimestamp has 1-second precision, and the UI orders the timeline by it, so space
        # out creates to keep them in order (oldest first)
        sleep 1
      elif grep -qi "already exists" <<<"$out"; then
        skipped=$((skipped + 1))
        continue
      else
        echo "$w: failed to create Freight for $version: $out" >&2
        continue
      fi
    fi
    created=$((created + 1))
  done < <(jq -c --arg project "$PROJECT" --argjson limit "$LIMIT" "$BUILD" <<<"$warehouse")

  verb=$([[ "$DRY_RUN" == "true" ]] && echo "would create" || echo "created")
  echo "$w: $verb $created, skipped $skipped already existing" >&2
done
