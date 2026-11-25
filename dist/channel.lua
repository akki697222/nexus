-- dist/channel.lua - where nexus-install finds the current release
--
-- The online installer reads this file from the main branch:
--   https://raw.githubusercontent.com/akki697222/nexus/main/dist/channel.lua
-- and downloads manifest.lua and the files it lists from
-- base:format(tag). Set the tag when a release is published (GitHub's
-- releases/latest skips pre-releases, so it cannot be used).
-- Data only: the installer loads it with an empty environment.
return {
    format = 1,
    base = "https://github.com/akki697222/nexus/releases/download/%s",
    channels = {
        stable = "v0.0.8",
    },
}
