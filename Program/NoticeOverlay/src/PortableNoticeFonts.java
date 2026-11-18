package minecraft.portable.notice;

import java.awt.Font;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.Properties;

/** Loads both physical faces once on the notice channel worker. */
final class PortableNoticeFonts {
    static final String ROBOTO_MODE = "roboto-v1";

    private final Font regular;
    private final Font semiBold;
    final String mode;

    private PortableNoticeFonts(Font regular, Font semiBold, String mode) {
        this.regular = regular;
        this.semiBold = semiBold;
        this.mode = mode;
    }

    static PortableNoticeFonts load(Path directory, Properties style) throws Exception {
        String mode = style.getProperty("fontMode", "");
        if (mode.isEmpty()) {
            // Old launchers supplied only a family. Java resolves that family or Dialog.
            String family = style.getProperty("fontFamily", Font.DIALOG);
            return new PortableNoticeFonts(new Font(family, Font.PLAIN, 1), new Font(family, Font.BOLD, 1), "");
        }
        if (!ROBOTO_MODE.equals(mode)) throw new IOException("Unrecognized game notice font mode");
        return new PortableNoticeFonts(
                loadFace(directory.resolve("Roboto-Regular.ttf"), 123720,
                        "dece7c71bbe61710787f0839c722c65e87355dd2eb4a823e6b5488121ff81e4b"),
                loadFace(directory.resolve("Roboto-SemiBold.ttf"), 124288,
                        "f478ba88b0292e685e487901dfbb1401457d32d6ebee4030cdfd5698235bffa8"),
                ROBOTO_MODE);
    }

    private static Font loadFace(Path path, int expectedLength, String expectedSha256) throws Exception {
        if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS) || Files.size(path) != expectedLength)
            throw new IOException("Missing or invalid game notice font: " + path.getFileName());
        MessageDigest sha256 = MessageDigest.getInstance("SHA-256");
        byte[] buffer = new byte[4096];
        int length = 0;
        try (InputStream stream = Files.newInputStream(path, LinkOption.NOFOLLOW_LINKS)) {
            for (int count; (count = stream.read(buffer)) != -1;) {
                length += count;
                if (length > expectedLength) throw new IOException("Game notice font grew during verification");
                sha256.update(buffer, 0, count);
            }
        }
        StringBuilder digest = new StringBuilder(64);
        for (byte value : sha256.digest()) {
            digest.append(Character.forDigit((value >>> 4) & 15, 16));
            digest.append(Character.forDigit(value & 15, 16));
        }
        if (length != expectedLength || !expectedSha256.contentEquals(digest))
            throw new IOException("Game notice font does not match its pin: " + path.getFileName());

        // Load the session file directly. The InputStream overload copies fonts to java.io.tmpdir.
        return Font.createFont(Font.TRUETYPE_FONT, path.toFile());
    }

    Font regular(float size) { return regular.deriveFont(size); }
    Font semiBold(float size) { return semiBold.deriveFont(size); }
}
