local colors = require("colors")

os.setenv("PATH", ".:/usr/bin:/usr/sbin:/bin:/sbin")
os.setenv("HOME", "/root")
os.setenv("USERNAME", "root")
os.setenv("PS1", colors.green .. "$USERNAME@$HOSTNAME" .. colors.bright_blue .. "$PWD" .. colors.reset .. "# ")