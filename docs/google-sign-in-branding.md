# Google sign-in button assets

The iOS `GoogleAuthenticationButton` follows the light theme in Google's
[branding guidelines](https://developers.google.com/identity/branding-guidelines).
It uses a white fill, #747775 border, #1F1F1F text, Google Sans Medium, and a
20-point full-color mark. The minimum height matches the Apple button at 56
points; the native text and button height can grow with Dynamic Type.

The mark comes from Google's [official asset bundle](https://developers.google.com/static/identity/images/signin-assets.zip),
downloaded on 2026-09-15. Each `GoogleSignInMark` PNG is the central 20 × 20-point
logo from the iOS light square icon button at its original 1x, 2x, or 3x scale.
Only the surrounding button padding and border were cropped away; the logo's
pixels, colors, and proportions are unchanged.

`Resources/Fonts/GoogleSans-Medium.ttf` is the unmodified static Medium face from
[Google Fonts](https://fonts.google.com/specimen/Google+Sans), downloaded on
2026-09-15. Its SIL Open Font License is bundled as `GoogleSans-OFL.txt`.
