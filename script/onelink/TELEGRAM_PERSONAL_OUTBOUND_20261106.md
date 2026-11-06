# Telegram Personal outbound serialization

The personal gateway previously received rendered HTML while send/send_file used
Telethon's default Markdown parser. Recipients saw literal `<strong>` and `<a>`.
Edits bypassed the renderer and explicitly disabled parsing. Temporary upload
basenames also replaced the attachment's original filename.

The app now sends `text_format: html` for sends and edits. Both use the same
escaped Telegram HTML renderer as the Bot channel; Bot behavior is unchanged.
Personal messages parse Markdown blocks before preserving source blank lines,
so lists and fenced code survive paragraph gaps. The gateway converts this HTML
to native text/entities for messages, captions, albums and edits.

This requires the separately reviewed gateway branch
`fix/telegram-outbound-20261106`, based on `5831921c836d9fd2afa286fdac84d4559c6f3efe`.
Its filename handling backports the accepted outbound-only change from
`802431a3..811703c30c478376a5b7453479df5ca2bd423b67`; Janus features from that
candidate are excluded. Native Telethon 1.40 infers document filenames from safe
upload basenames, preserving its normal media attributes.

Update the gateway before the app. Requests without `text_format` keep legacy
send parsing and plain edit behavior; explicit `plain` preserves literal text.
A gateway-only update does not repair formatting until the app declares HTML.
Neither this branch nor its tests authorize deployment or sending real messages.
