# sh

## ⚠️ DISCLAIMER

THESE SHELL SCRIPTS ONLY FOR PERSONAL USE AND HAVE NOT BEEN VERIFIED. THEY MAY DAMAGE YOUR DEVICE.OWN YOUR RISKS.

이 레포지토리의 모든 쉘-스크립트들은 개인이 사용하기위해 작성되었으며 검증되지 않았습니다. 당신의 기기에 치명적인 피해를 줄 수 있습니다. 책임은 당신에게 있습니다.


## Automation GPG sign checksum

```sh
# Generate GPG {private|public} key unnessasary passphrase.
$ gpg --batch --generate-key <<EOF
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: {your name}
Name-Email: {your email}
Expire-Date: 0
%no-protection
%commit
EOF


# View GPG list
$ gpg --list-secret-keys --keyid-format LONG
.
.
[keyboxd]
---------
sec   rsa4096/B4E9FF74C9005083 2025-10-04 [SCEAR] # "B4E9FF74C9005083" is your key
      FAD047104A0AF92E1F13A43AB4E9FF74C9005083
uid                 [ultimate] {your name} <{your email}>
ssb   rsa4096/4AFD5EAD72C3C48F 2023-08-01 [SEA]
.
.

# Export GPG public key
$ gpg --armor --export B4E9FF74C9005083 > gpg-github-public-key.asc

# Export GPG private key for 'Github Actions'
$ gpg --armor --export-secret-keys B4E9FF74C9005083 > gpg-github-private-key.asc
```

## Register environment secrets, variables 

### Environment secrets

Settings `>` Secrets and variables `>` Actions

| Variable name   | Value                              |
|-----------------|------------------------------------|
| GPG_PRIVATE_KEY | {`cat gpg-github-private-key.asc`} |

## Environment variables

| Name          | Variable                    |
|---------------|-----------------------------|
| GIT_BOT_NAME  | {your workflow bot's name}  |
| GIT_BOT_EMAIL | {your workflow bot's email} |


## Add workflows action file

```yml
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
            git commit -m "GPG signed via giuthub workflow"
            git push
          fi
        env:
          GIT_BOT_NAME: ${{ vars.GIT_BOT_NAME }}
          GIT_BOT_EMAIL: ${{ vars.GIT_BOT_EMAIL }}
```