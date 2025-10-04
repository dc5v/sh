# sh

## ⚠️ DISCLAIMER

THESE SHELL SCRIPTS ONLY FOR PERSONAL(Author) USE AND HAVE NOT BEEN VERIFIED. THEY MAY DAMAGE YOUR DEVICE.OWN YOUR RISKS.

이 레포지토리의 모든 쉘-스크립트들은 개인(작성자)이 사용하기위해 작성되었으며 검증되지 않았습니다. 당신의 기기에 치명적인 피해를 줄 수 있습니다. 책임은 당신에게 있습니다.

---

## Register GPG automatic signing

> The following instructions are based on Arch Linux.

Register GPG automatic signing using GitHub workflows.


### Generate GPG public, private key

Store the generated private key and public key files in a my safe storage or device.

```sh
# Install gnupg
#
sudo pacman -Syu gnupg

# Generate GPG public and private key without passphrase, 
# using only the private key.
#
# Replace {my name}, {my email}
#
$ gpg --batch --generate-key <<EOF
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: {my name}
Name-Email: {my email}
Expire-Date: 0
%no-protection
%commit
EOF

# Check GPG key list
#
$ gpg --list-secret-keys --keyid-format LONG
.
.
[keyboxd]
---------
sec   rsa4096/B4E9FF74C9005083 2025-10-04 [SCEAR] # "B4E9FF74C9005083" is generated my key
      FAD047104A0AF92E1F13A43AB4E9FF74C9005083
uid                 [ultimate] {my name} <{my email}>
ssb   rsa4096/4AFD5EAD72C3C48F 2023-08-01 [SEA]
.
.

# Export GPG "public key"
#
$ gpg --armor --export B4E9FF74C9005083 > gpg-github-workflows-public-key.asc

# Export GPG "private key" for use in GitHub workflows
#
$ gpg --armor --export-secret-keys B4E9FF74C9005083 > gpg-github-workflows-private-key.asc
```

### Register environment variables 

Register (secret) environment variables for use in GitHub workflows.

> _You can find it by following the menu below.(2025-October)_
>
> _`Settings` > `Secrets and variables` > `Actions`_


### Secrets Environment 

My GPG private key for signing. Copy and paste the full contents of `gpg-github-workflows-private-key.asc`.

| Variable name   | Value                                  |
|-----------------|----------------------------------------|
| GPG_PRIVATE_KEY | {Full contents of my private key here} |

```sh
# Check my GPG private key
#
cat gpg-github-workflows-private-key.asc
.
.
-----BEGIN PGP PRIVATE KEY BLOCK-----

lQcYBGjg0BoBEADcpjxC1TFC2NwONvNcYrg9nvm/MnRHt0xZ1AcFrSQ5nUVqNjYy
THiQNU9oB5Yp4rB2VimIyi0paZDtUfGR0qV/Sc1rh+mn2objCRWT7iNfRe5XWE8D
.
.
=1W75
-----END PGP PRIVATE KEY BLOCK-----

```

### Environment Variables

My workflow automatic bot's commit username and email.

| Name          | Variable          |
|---------------|-------------------|
| GIT_BOT_NAME  | {commit username} |
| GIT_BOT_EMAIL | {commit email}    |


### Add workflows action yaml

The below script intended to automatically GPG signing committed *.sh files when I push to remote repository.

Update the following content to fit my requirements.

```sh
# Make directories and create empty workflow yaml file. 
#
mkdir -p .github/workflows

# Create workflow yaml file for automatic signing.
#
cat << EOF > .github/workflows/test.yml
name: Sign only changed .sh files

on:
  push:
    branches: [ "main" ]
    paths:
      - "*.sh"

jobs:
  selective-sign:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
        with:
          fetch-depth: 2

      - name: Import GPG private key
        run: echo "$GPG_PRIVATE_KEY" | gpg --batch --import
        env:
          GPG_PRIVATE_KEY: ${{ secrets.GPG_PRIVATE_KEY }}

      - name: GPG Sign only changed files
        run: |
          files=$(git diff --name-only HEAD~1 HEAD | grep '\.sh$' || true)
          [ -z "$files" ] && echo "No .sh changes, skipping." && exit 0

          for f in $files; do
            [ -f "$f" ] || continue

            echo "- Filename: $f"
            sha256sum "$f" > "$f.sha256"
            gpg --batch --yes --pinentry-mode loopback --passphrase "" --armor --detach-sign --output "$f.asc" "$f"
          done

      - name: Commit, Push
        run: |
          git config user.name "${GIT_BOT_NAME}"
          git config user.email "${GIT_BOT_EMAIL}"
          git add *.asc *.sha256 || true

          if ! git diff --cached --quiet; then
            git commit -m "GPG signed via github workflow"
            git push
          fi
        env:
          GIT_BOT_NAME: ${{ vars.GIT_BOT_NAME }}
          GIT_BOT_EMAIL: ${{ vars.GIT_BOT_EMAIL }}
EOF
```

```