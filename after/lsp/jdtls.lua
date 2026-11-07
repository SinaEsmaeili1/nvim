-- jdtls cannot run on Java 27 yet ("Unsupported class file major version 71"), so start the server
-- with an LTS JDK when one is installed. Programs are still run with the default `java`.
local cmd_env = nil

for _, jdk in ipairs { "/usr/lib/jvm/java-25-openjdk", "/usr/lib/jvm/java-21-openjdk" } do
  if vim.uv.fs_stat(jdk .. "/bin/java") then
    cmd_env = { JAVA_HOME = jdk }
    break
  end
end

return {
  cmd_env = cmd_env,
}
