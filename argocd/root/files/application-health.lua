-- Health of argoproj.io/Application resources, for the app of apps (argocd-cm resource.customizations).
-- Argo CD does not assess Applications by default; without this, the root app would not wait for one sync
-- wave of child Applications to be healthy before starting the next.
hs = {}
hs.status = "Progressing"
hs.message = ""
if obj.status ~= nil and obj.status.health ~= nil then
  hs.status = obj.status.health.status
  if obj.status.health.message ~= nil then
    hs.message = obj.status.health.message
  end
end
return hs
