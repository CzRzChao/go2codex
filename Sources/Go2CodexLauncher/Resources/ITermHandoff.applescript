on go2codexNewWindow(commandText)
    using terms from application "iTerm"
        tell application id "com.googlecode.iterm2"
            with timeout of 60 seconds
                set createdWindow to create window with default profile
                try
                    tell current session of createdWindow to write text commandText newline true
                on error errorMessage number errorNumber
                    try
                        close createdWindow
                    end try
                    error errorMessage number errorNumber
                end try
            end timeout
        end tell
    end using terms from
    return true
end go2codexNewWindow

on go2codexNewTab(commandText)
    using terms from application "iTerm"
        tell application id "com.googlecode.iterm2"
            with timeout of 60 seconds
                set targetWindow to current window
                tell targetWindow to set createdTab to create tab with default profile
                try
                    tell current session of createdTab to write text commandText newline true
                on error errorMessage number errorNumber
                    try
                        close createdTab
                    end try
                    error errorMessage number errorNumber
                end try
            end timeout
        end tell
    end using terms from
    return true
end go2codexNewTab
