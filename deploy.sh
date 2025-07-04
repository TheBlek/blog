#!/usr/bin/env sh

hugo build

git add -A

git commit -m "Deploy"

git push

ssh theblek.online "cd landing && git pull"

