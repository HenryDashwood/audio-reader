// The downloadable natural voice as an on-demand Play asset pack. Play fetches it only when she taps Download.
// Its files are text-to-speech notebook 107's voice_folder("android"), copied in by `scripts/voice-pack.sh android`;
// they're too large for Git, so settings.gradle.kts leaves this module out of builds that haven't been given them.
plugins {
    id("com.android.asset-pack")
}

assetPack {
    packName.set("natural_voice")
    dynamicDelivery {
        deliveryType.set("on-demand")
    }
}
