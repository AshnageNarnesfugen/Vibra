// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get homeTab => 'Home';

  @override
  String get libraryTab => 'Library';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get cancel => 'Cancel';

  @override
  String get settingsAccountTitle => 'YouTube Music account';

  @override
  String get settingsAccountActive => 'Signed in — personal library enabled';

  @override
  String get settingsAccountOauthLimited =>
      'OAuth saved but limited by Google — use a cookie';

  @override
  String get settingsAccountNone => 'Not signed in — public search only';

  @override
  String get settingsBackgroundTitle => 'Background';

  @override
  String get settingsBackgroundSubtitle =>
      'Solid color or adjustable image, opacity';

  @override
  String get settingsEffectsTitle => 'Effects';

  @override
  String get settingsEffectsSubtitle => 'Blur, noise and tilt parallax';

  @override
  String get settingsThemeTitle => 'Theme & color';

  @override
  String get settingsThemeSubtitle =>
      'Dynamic color from the artwork or a default accent';

  @override
  String get settingsSpacingTitle => 'Spacing & corners';

  @override
  String get settingsSpacingSubtitle => 'Density and uniform corner radius';

  @override
  String get settingsAnimationsTitle => 'Animations';

  @override
  String get settingsAnimationsSubtitle => 'Transition style and duration';

  @override
  String get settingsQualityTitle => 'Audio & video quality';

  @override
  String get settingsQualitySubtitle =>
      'Different bitrate on WiFi vs mobile data; download quality';

  @override
  String get settingsStorageTitle => 'Storage';

  @override
  String get settingsStorageSubtitle =>
      'Where downloaded music lives and the app folders';

  @override
  String get settingsEqTitle => 'Equalizer';

  @override
  String get settingsEqSubtitle =>
      'Bands + preamp + presets (Rock, Bass Boost, V-Shape…) and custom mixes';

  @override
  String get settingsHifiTitle => 'Hi-Fi mode (bit-perfect)';

  @override
  String get settingsHifiSubtitle =>
      'Disables EQ, fades and processing; output device monitor and AAudio capability';

  @override
  String get settingsFloatingTitle => 'Floating mini';

  @override
  String get settingsFloatingSubtitle =>
      'System-overlay pill widget with cover + controls (experimental, Android only)';

  @override
  String get settingsLanguageTitle => 'Language';

  @override
  String get settingsLanguageSubtitle =>
      'Follows the system or set it manually';

  @override
  String get settingsReset => 'Reset settings';

  @override
  String get languageSystem => 'System';

  @override
  String get languageScreenHint =>
      'By default Vibra uses your device language. Pick one here to override it for the app only.';

  @override
  String get qualityAudioWifi => 'Audio on WiFi';

  @override
  String get qualityAudioCellular => 'Audio on mobile data';

  @override
  String get qualityAudioCellularSubtitle =>
      'Defaults to medium to save your data plan. Raise it to high if you have unlimited data.';

  @override
  String get qualityVideoWifi => 'Video on WiFi';

  @override
  String get qualityVideoWifiSubtitle =>
      'Music video image resolution. Changes apply to the next video that loads.';

  @override
  String get qualityVideoCellular => 'Video on mobile data';

  @override
  String get qualityVideoCellularSubtitle =>
      'Defaults to low — 5 minutes of 720p+ music video uses ~100MB.';

  @override
  String get qualityDownloads => 'Download quality';

  @override
  String get qualityDownloadsSubtitle =>
      'Applies to songs downloaded for offline playback. Files stay on your device.';

  @override
  String get qualityAudioLow => 'Low (~96 kbps)';

  @override
  String get qualityAudioMedium => 'Medium (~160 kbps)';

  @override
  String get qualityAudioHigh => 'High';

  @override
  String get qualityVideoLow => 'Low (360p)';

  @override
  String get qualityVideoMedium => 'Medium (720p)';

  @override
  String get qualityVideoHigh => 'High (best available)';

  @override
  String get autoplayTitle => 'Autoplay when the queue ends';

  @override
  String get autoplaySubtitle =>
      'When your streaming queue ends (repeat off), keep going with songs related to the last one — like YT Music. Turn it off if you prefer playback to stop.';

  @override
  String get downloadAsMp3Title => 'Download as MP3';

  @override
  String get downloadAsMp3Subtitle =>
      'Converts downloads to 256 kbps MP3 with embedded metadata (title, artist, album and cover art) — maximum compatibility with other apps and devices. Conversion takes ~1-2 min per song. Off: keeps the original stream (m4a/opus), faster and with no re-compression.';

  @override
  String get downloadsTitle => 'Downloads';

  @override
  String get downloadsCancelAll => 'Cancel all';

  @override
  String downloadsQueuedHeader(int count) {
    return 'Queued · $count';
  }

  @override
  String downloadsDoneHeader(int count) {
    return 'Downloaded · $count';
  }

  @override
  String get downloadsEmptyQueue => 'No downloads queued.';

  @override
  String get downloadsEmptyDone =>
      'You haven\'t downloaded any songs yet. Use \"Download\" in a streaming song\'s menu.';

  @override
  String get downloadsConverting => 'Converting…';

  @override
  String downloadsWaiting(String position) {
    return 'Waiting · #$position';
  }

  @override
  String get downloadsUnavailable => 'The download service is unavailable.';

  @override
  String get downloadsDeleteTooltip => 'Delete download';

  @override
  String get actionPlay => 'Play';

  @override
  String get actionShuffle => 'Shuffle';

  @override
  String get actionPlayNext => 'Play next';

  @override
  String get actionAddToQueue => 'Add to current queue';

  @override
  String get actionSaveToPlaylist => 'Save to playlist';

  @override
  String get actionDownload => 'Download for offline';

  @override
  String get actionDownloadAll => 'Download all';

  @override
  String get actionRemoveDownload => 'Remove download';

  @override
  String get actionRemoveDownloads => 'Remove downloads';

  @override
  String get actionInQueue => 'Queued…';

  @override
  String get actionDownloadsUnavailable => 'Downloads unavailable';

  @override
  String get actionGoToArtist => 'Go to artist';

  @override
  String get actionGoToAlbum => 'Go to album';

  @override
  String snackDownloading(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Downloading $count songs…',
      one: 'Downloading 1 song…',
    );
    return '$_temp0';
  }

  @override
  String snackDeletedDownloads(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count downloads removed.',
      one: '1 download removed.',
    );
    return '$_temp0';
  }

  @override
  String snackAddedToQueue(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Added $count songs to the end of the queue.',
      one: 'Added 1 song to the end of the queue.',
    );
    return '$_temp0';
  }

  @override
  String get speedPitchTitle => 'Speed & pitch';

  @override
  String get speedLabel => 'Speed';

  @override
  String get pitchLabel => 'Pitch (semitones)';

  @override
  String get pitchLockedHint =>
      'Pitch locked to speed — the pitch slider is disabled.';

  @override
  String get chipmunkTitle => 'Pitch follows speed (chipmunk)';

  @override
  String get chipmunkSubtitle =>
      'Raising the speed raises the pitch and vice versa, like an old tape. Default: independent pitch.';

  @override
  String get sleepTimerTitle => 'Sleep timer';

  @override
  String get sleepAtTrackEnd => 'End of song';

  @override
  String sleepMinutes(int minutes) {
    return '$minutes min';
  }

  @override
  String get sleepStatusTrackEnd => 'Playback will pause when this song ends.';

  @override
  String sleepStatusAt(String time) {
    return 'Will pause at $time.';
  }

  @override
  String get nowPlaying => 'Now playing';

  @override
  String get nothingPlaying => 'Nothing playing.';

  @override
  String get tooltipShowQueue => 'Show queue';

  @override
  String get tooltipHideQueue => 'Hide queue';

  @override
  String get tooltipShowCover => 'Show cover';

  @override
  String get tooltipShowVideo => 'Show video';

  @override
  String get tooltipChangeColor => 'Change color';

  @override
  String get tooltipShowLyrics => 'Show lyrics';

  @override
  String get tooltipHideLyrics => 'Hide lyrics';

  @override
  String get tooltipMoreOptions => 'More options';

  @override
  String get onboardSkip => 'Skip';

  @override
  String get onboardNext => 'Next';

  @override
  String get onboardWelcomeTitle => 'Welcome to Vibra';

  @override
  String get onboardWelcomeBody =>
      'Your local music and the YouTube Music catalog in a single player, with an interface that takes on the colors of each album cover. Backgrounds, shapes and animations: everything is customizable in Settings.';

  @override
  String get onboardLibraryTitle => 'Library & downloads';

  @override
  String get onboardLibraryBody =>
      'Vibra scans the music on your device and groups it by albums and artists. Streaming songs can be downloaded (⋮ menu → Download) and are saved as MP3 with cover art in a public folder — visible from your file manager and other apps.';

  @override
  String get onboardAccountTitle => 'Your account (optional)';

  @override
  String get onboardAccountBody =>
      'Without an account you can search and play the whole catalog. Signing in with Google also unlocks your personal library: your playlists, likes, history and tailored recommendations.';

  @override
  String get onboardSignIn => 'Sign in with Google';

  @override
  String get onboardExplore => 'Explore without an account';
}
