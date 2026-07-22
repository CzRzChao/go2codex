on go2codexNewWindow(commandText)
    using terms from application "iTerm"
        tell application id "com.googlecode.iterm2"
            with timeout of 60 seconds
                create window with default profile command commandText
            end timeout
        end tell
    end using terms from
    return true
end go2codexNewWindow

on go2codexNewTab(commandText)
    using terms from application "iTerm"
        tell application id "com.googlecode.iterm2"
            with timeout of 60 seconds
                tell current window to create tab with default profile command commandText
            end timeout
        end tell
    end using terms from
    return true
end go2codexNewTab
