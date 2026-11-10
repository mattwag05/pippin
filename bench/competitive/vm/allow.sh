#!/bin/sh
# VM only: clicks "Allow" on pending macOS automation consent dialogs.
perl -e 'alarm 20; exec @ARGV' osascript -e 'tell application "System Events"
set out to ""
repeat with p in (every process whose name is "UserNotificationCenter")
repeat with w in (every window of p)
set t to ""
try
set t to (value of static text 1 of w) as text
end try
if exists (button "Allow" of w) then
click button "Allow" of w
set out to out & "clicked Allow: " & t & linefeed
else
set out to out & "no Allow button: " & t & " buttons=" & (name of every button of w as text) & linefeed
end if
end repeat
end repeat
return out
end tell'
