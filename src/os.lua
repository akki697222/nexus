function os.getenv(key)
    return process.getEnviron(key)
end

function os.setenv(key, value)
    process.setEnviron(key, value)
end

function os.exit(code)
    process.exit(code)
end
