# Fleet Management Demo

Demonstrates managing a large fleet of clusters with Kargo and Argo CD.

## Layout

| Path | Contents |
|---|---|
| `inventory/clusters/` | Cluster inventory, one file per cluster, named `<env>.<cloud>.<geo>.<metro>.<3-digit-id>.yaml`, with the cluster's `cloud` and provider `region` as fields |
| `charts/<addon>/` | A dummy Helm chart per add-on. Each directory here becomes an add-on on every cluster |
| `setup/cluster-addons/argocd/` | Argo CD AppProject and ApplicationSet: one Application per cluster × add-on |
| `setup/cluster-addons/kargo/` | Kargo Project, Warehouses (one per add-on), TargetSet (one target per cluster), Stages (`test`, `stg.<geo>`, the `prod` gate, `prd.<geo>`) and PromotionTask |
| `setup/kargo-system/` | Shared Kargo resources (custom promotion steps) |

## Setup

### Prerequisites

- The `argocd` and `kargo` CLIs.
- An Argo CD instance with a cluster registered under the name `demo`, and a Kargo instance that can manage that Argo CD's Applications.

### Argo CD

```sh
argocd login <argocd-server>

# AppProject restricting the add-ons to this repo, the demo cluster's cluster-addons namespace,
# and namespaced resources (plus creating the cluster-addons Namespace itself)
argocd proj create -f setup/cluster-addons/argocd/00_project.yaml --upsert

# ApplicationSet: one Application per cluster in inventory/clusters/ × chart in charts/
argocd appset create setup/cluster-addons/argocd/appset.yaml --upsert
```

Verify that the Applications were generated:

```sh
argocd app list -l appset=cluster-addons
```

### Kargo

```sh
kargo login <kargo-server>

# Shared custom promotion steps
kargo apply -f setup/kargo-system/

# Cluster add-ons: Project, Warehouses + add-on image ConfigMap, TargetSet, PromotionTask and Stages
kargo apply -f setup/cluster-addons/kargo/
```

`kargo apply` creates the Project before the resources inside it, so the whole directory can be applied at once.

Verify:

```sh
kargo get warehouses --project cluster-addons
kargo get stages --project cluster-addons
kargo get freight --project cluster-addons
```

## Promoting an add-on

Each add-on has its own Warehouse, and every Stage requests Freight from all of them. Freight goes to a single `test` Stage (every `tst` cluster), then fans out to a `stg.<geo>` Stage for each geo (`na`, `latam`, `eu`, `apac`, `gov`). Before production it passes through `prod`, a control-flow Stage with no clusters or promotion steps: Freight only becomes available there once it has been verified in every `stg.<geo>` Stage. From `prod`, it fans out again to the `prd.<geo>` Stages. Promoting a piece of Freight updates that add-on's Application on every cluster in the Stage.

```sh
# Promote the latest kyverno Freight to test
kargo promote --project cluster-addons --warehouse kyverno --stage test

# Then onward to every stg.<geo> Stage
kargo promote --project cluster-addons --freight-alias <alias> --downstream-from test

# Once it's verified in all of them, through the prod gate and on to every prd.<geo> Stage
kargo promote --project cluster-addons --freight-alias <alias> --stage prod
kargo promote --project cluster-addons --freight-alias <alias> --downstream-from prod
```

## Simulated failures

A few clusters have `fail: "true"` in their inventory file. The TargetSet passes it to each target as the `fail` param, and the `promote` PromotionTask runs a `fail` step first on those targets, so promoting to them always fails.

Each Stage tolerates some failed targets: `maxFailures: "5%"` of the clusters it selects, rounded up. The failing clusters are spread so every Stage but `prd.latam` stays under that limit, so its promotion still succeeds and Freight moves on. `prd.latam` goes over it on purpose, to show a rollout failing fast:

| Stage | Clusters | Failing | Tolerated |
|---|---|---|---|
| `test` | 24 | 1 | 2 |
| `prd.na` | 112 | 4 | 6 |
| `prd.eu` | 80 | 2 | 4 |
| `prd.apac` | 64 | 2 | 4 |
| `prd.latam` | 40 | 3 | 2 |
| `prd.gov` | 24 | 1 | 2 |

Targets are promoted in name order, so a rollout's progress is predictable. `prd.latam` uses `maxConcurrent: 5`, so it starts with its first 5 targets (`prd.aws.latam.br-saopaulo.001`–`.005`), which succeed. As slots free up, the next targets in name order start: `.006`, `.007` and `.008`, which all fail. The third failure goes over the budget, so the rollout fails and starts no more targets. The other 32 clusters stay on the old Freight.

To see another promotion fail, add `fail: "true"` to more clusters in a Stage than it tolerates (e.g. 3 `tst` clusters), or lower its `maxFailures`. To list the failing clusters:

```sh
grep -l 'fail: "true"' inventory/clusters/*
```

## Adding a cluster

Add a file to `inventory/clusters/` and push. The name is `<env>.<cloud>.<geo>.<metro>.<3-digit-id>`, where the metro is `<country>-<city>` of the provider region (e.g. AWS `eu-west-1`, Azure `northeurope` → `ie-dublin`). The 3-digit ID counts clusters per env, cloud, geo and metro, since one cloud can have several regions in a metro:

```sh
cat > inventory/clusters/prd.aws.eu.ie-dublin.099.yaml <<EOF
cluster: prd.aws.eu.ie-dublin.099
cloud: aws
region: eu-west-1
EOF
```

The ApplicationSet creates an Application for each add-on in `charts/`, and the TargetSet adds it as a target of the matching Stage: `test` for `tst` clusters, otherwise `<env>.<geo>`.

## Adding an add-on

An add-on is a chart in `charts/` plus a Warehouse in Kargo, both named after the add-on. The name must be the same everywhere, because Kargo uses the Warehouse name to find the add-on's Applications (`<cluster>.<addon>`) and its image. For example, to add `argo-rollouts`:

1. **Add a chart.** Copy an existing add-on chart and rename it:

   ```sh
   cp -R charts/kyverno charts/argo-rollouts
   sed -i '' 's/^name: kyverno$/name: argo-rollouts/' charts/argo-rollouts/Chart.yaml
   ```

   The ApplicationSet picks up every directory under `charts/`, so once pushed, Argo CD creates an `<cluster>.argo-rollouts` Application on every cluster. Until the first promotion, it runs the chart's default image.

2. **Add a Warehouse** subscribed to the add-on's image in `setup/cluster-addons/kargo/warehouses.yaml`:

   ```yaml
   ---
   apiVersion: kargo.akuity.io/v1alpha1
   kind: Warehouse
   metadata:
     name: argo-rollouts
     namespace: cluster-addons
   spec:
     subscriptions:
     - image:
         repoURL: quay.io/argoproj/argo-rollouts
         imageSelectionStrategy: SemVer
         discoveryLimit: 10
   ```

3. **Add the image to the `addon-images` ConfigMap** at the top of the same file, using the same repo URL as the Warehouse. The PromotionTask reads it to set the image on the Application:

   ```yaml
   data:
     argo-rollouts: quay.io/argoproj/argo-rollouts
   ```

4. **Request its Freight in every Stage** in `setup/cluster-addons/kargo/stages.yaml`. Each Stage lists every add-on's Warehouse under `requestedFreight`. The `test` Stage takes Freight directly from the Warehouse, `stg.<geo>` Stages take it from `test`, the `prod` gate from all `stg.<geo>` Stages, and `prd.<geo>` Stages from `prod`:

   ```yaml
   # test
   - origin: { kind: Warehouse, name: argo-rollouts }
     sources: {direct: true}
   # stg.<geo> (prd.<geo> uses stages: [prod])
   - origin: { kind: Warehouse, name: argo-rollouts }
     sources: {stages: [test]}
   # prod
   - origin: { kind: Warehouse, name: argo-rollouts }
     sources: {stages: [stg.na, stg.latam, stg.eu, stg.apac, stg.gov], availabilityStrategy: All}
   ```

5. **Apply and push:**

   ```sh
   kargo apply -f setup/cluster-addons/kargo/
   git add charts/argo-rollouts && git commit -m "Add argo-rollouts add-on" && git push
   ```

Then promote it like any other add-on:

```sh
kargo promote --project cluster-addons --warehouse argo-rollouts --stage test
```

If the chart is pushed without steps 2–4, Argo CD still deploys the add-on to every cluster, but Kargo has no Freight for it and can never promote it.
