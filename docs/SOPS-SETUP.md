# SOPS + age Secret Management Setup

**Date**: March 1, 2026  
**Status**: Configured and documented

## Overview

This cluster uses SOPS + age for managing encrypted secrets in git. Only the **Live TV services** (pluto-for-channels, EPlusTV, etc.) require encrypted secrets. Other services are UI-configured and don't need secret encryption.

## Prerequisites

Install age and sops:
```bash
brew install age sops
```

## Bootstrap: One-time K8s Secret Creation

The age keypair is generated locally and used to encrypt/decrypt secrets via `.sops.yaml`. The private key must be stored in the cluster as a Kubernetes secret for Flux to decrypt secrets at deploy time.

### Step 1: Generate age keypair (if not already done)

```bash
age-keygen -o age.key
```

Output: private key saved to `age.key`, public key shown in stdout.

### Step 2: Add private key to K8s cluster

This must be done **once per cluster** when SOPS is first enabled:

```bash
kubectl create secret generic sops-age \
  --from-file=age.agekey=age.key \
  -n flux-system

# Verify
kubectl get secret sops-age -n flux-system
```

**Important**: 
- Do NOT commit `age.key` to git (it's in `.gitignore`)
- Back up `age.key` securely in your password manager
- If lost, you cannot decrypt existing secrets — you must regenerate the keypair and re-encrypt all secrets

## Encrypting Secrets

### Plaintext Template

Create a plaintext secret file, e.g. `clusters/homelab/apps/media/pluto-for-channels/secret.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: pluto-secrets
  namespace: media
type: Opaque
data:
  username: <base64-encoded-username>  # Use `echo -n "user" | base64`
  password: <base64-encoded-password>
```

**Alternative**: Use `stringData` (no base64 encoding needed):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: pluto-secrets
  namespace: media
type: Opaque
stringData:
  username: your-pluto-username
  password: your-pluto-password
```

### Encrypt the Secret

```bash
sops --encrypt clusters/homelab/apps/media/pluto-for-channels/secret.yaml \
  > clusters/homelab/apps/media/pluto-for-channels/secret.enc.yaml
```

This replaces `data` or `stringData` values with encrypted ciphertexts. Metadata (kind, name, namespace) remains plaintext.

**Result**: Commit `secret.enc.yaml` to git, delete plaintext `secret.yaml`.

### Decrypt for Local Review (Optional)

```bash
sops --decrypt clusters/homelab/apps/media/pluto-for-channels/secret.enc.yaml
```

Or save to a local decrypted copy:

```bash
sops --decrypt clusters/homelab/apps/media/pluto-for-channels/secret.enc.yaml \
  > /tmp/secret.dec.yaml
```

## Flux Integration

Flux automatically decrypts SOPS secrets during reconciliation. No additional configuration is needed beyond:

1. ✅ `.sops.yaml` exists in repo root (defines public key)
2. ✅ Plaintext secret name ends in `secret.yaml` or `secret.enc.yaml`
3. ✅ K8s secret `sops-age` exists in `flux-system` namespace
4. ✅ Secret is referenced in a `Kustomization` resource

Example `kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../ (parent dir with encrypted secret)
  - secret.enc.yaml  # Or just list it directly
```

Flux will:
1. Detect `secret.enc.yaml` in the `Kustomization`
2. Read the `sops-age` secret from `flux-system` namespace
3. Decrypt the secret using the age private key
4. Apply plaintext secret to cluster

## Workflow: Add a New Encrypted Secret

1. **Create plaintext secret**:
   ```bash
   cat > clusters/homelab/apps/media/eplustv/secret.yaml << 'EOF'
   apiVersion: v1
   kind: Secret
   metadata:
     name: eplustv-secrets
     namespace: media
   type: Opaque
   stringData:
     espn_username: your-espn-email
     espn_password: your-espn-password
     flosports_username: your-flo-email
     flosports_password: your-flo-password
   EOF
   ```

2. **Encrypt it**:
   ```bash
   sops --encrypt clusters/homelab/apps/media/eplustv/secret.yaml \
     > clusters/homelab/apps/media/eplustv/secret.enc.yaml
   ```

3. **Delete plaintext**:
   ```bash
   rm clusters/homelab/apps/media/eplustv/secret.yaml
   ```

4. **Commit encrypted secret**:
   ```bash
   git add clusters/homelab/apps/media/eplustv/secret.enc.yaml
   git commit -m "feat: add eplustv secrets (SOPS-encrypted)"
   git push
   ```

5. **Verify in cluster**:
   ```bash
   kubectl get secret eplustv-secrets -n media
   kubectl get secret eplustv-secrets -n media -o jsonpath='{.data.espn_username}' | base64 -d
   ```

## Troubleshooting

### "Error decrypting secret"

**Cause**: Flux can't find `sops-age` secret in `flux-system` namespace.

**Fix**:
```bash
kubectl get secret sops-age -n flux-system
# If not found, create it:
kubectl create secret generic sops-age \
  --from-file=age.agekey=age.key \
  -n flux-system
# Reconcile:
flux reconcile kustomization flux-system --with-source
```

### "sops: invalid key"

**Cause**: `.sops.yaml` public key doesn't match the age.key private key.

**Fix**:
1. Check `.sops.yaml` public key:
   ```bash
   grep "age" .sops.yaml
   ```
2. Check `age.key`:
   ```bash
   cat age.key | grep "public key"
   ```
3. If they don't match, regenerate keypair and update `.sops.yaml`.

### "Secret not being decrypted in cluster"

**Cause**: Flux hasn't reconciled yet, or secret is not in a `Kustomization` resource.

**Fix**:
```bash
# Force reconcile
flux reconcile kustomization apps --with-source

# Check Flux logs
flux logs --all-namespaces --follow
```

## Reference

- `.sops.yaml` — Root config file defining encryption rules and public key
- `age.key` — Private key (local only, in `.gitignore`)
- `sops-age` secret — K8s secret containing `age.agekey`, used by Flux for decryption
- Encrypted secrets — Files named `secret.enc.yaml` with encrypted `data`/`stringData`

## Key Rotation (Advanced)

If you need to rotate the age key in the future:

1. Generate new keypair
2. Update `.sops.yaml` with new public key
3. Update `sops-age` K8s secret with new private key
4. Re-encrypt all secrets with `sops --encrypt --in-place`
5. Commit and push

For now, safeguard the current `age.key` — it's your only way to decrypt live secrets.
