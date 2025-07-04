#!/usr/bin/env sh

git add -A

git commit -m "Deploy"

ssh theblek.online

cd landing

git pull

exit

