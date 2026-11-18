package minecraft.portable.notice;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;
import java.awt.Font;
import java.awt.Graphics2D;
import java.awt.image.BufferedImage;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Properties;

/** Bytecode contract checks, run against the actual packaged transformer. */
public final class TransformerAudit {
    public static void main(String[] arguments) throws Exception {
        audit("org/lwjgl/glfw/GLFW", "glfwSwapBuffers", "(J)V", false);
        audit("org/lwjgl/opengl/Display", "swapBuffers", "()V", false);
        audit("org/lwjgl/sdl/SDLVideo", "SDL_GL_SwapWindow", "(J)Z", false);
        audit("org/lwjgl/glfw/GLFW", "glfwSwapBuffers", "(J)V", true);
        byte[] unrelated = fixture("example/Unrelated", "swapBuffers", "()V", false);
        if (new PortableNoticeTransformer().transform(null, "example/Unrelated", null, null, unrelated) != null) {
            throw new AssertionError("Unrelated classes must be untouched");
        }
        windowTitleContracts();
        snapshotContracts();
        scaleContracts();
        fontContract(arguments);
        System.out.println("Presentation transformer contracts passed (LWJGL2, LWJGL3, SDL3, native refusal, unrelated class).");
    }

    private static void fontContract(String[] arguments) throws Exception {
        if (arguments.length == 0) return; // Standalone bytecode probe.
        Path fixture = Paths.get(arguments[0]);
        Properties style = new Properties();
        PortableNoticeFonts legacy = PortableNoticeFonts.load(fixture, style);
        if (!legacy.mode.isEmpty() || !Font.DIALOG.equals(legacy.regular(14).getFamily())) {
            throw new AssertionError("An older launcher without TTF resources stopped working");
        }
        style.setProperty("fontMode", PortableNoticeFonts.ROBOTO_MODE);
        expectFontFailure(fixture, style);
        Files.write(fixture.resolve("Roboto-Regular.ttf"), new byte[123720]);
        expectFontFailure(fixture, style);
        Files.delete(fixture.resolve("Roboto-Regular.ttf"));
        if (arguments.length == 1) return;

        Path bundle = Paths.get(arguments[1]);
        PortableNoticeFonts fonts = PortableNoticeFonts.load(bundle, style);
        Font regular = fonts.regular(14);
        Font semiBold = fonts.semiBold(14);
        if (!PortableNoticeFonts.ROBOTO_MODE.equals(fonts.mode) ||
                !regular.getPSName().equals("Roboto-Regular") || !semiBold.getPSName().equals("Roboto-SemiBold")) {
            throw new AssertionError("The renderer did not open both physical faces");
        }
        String sample = "Мой мир — ждём тебя";
        if (regular.canDisplayUpTo(sample) != -1 || semiBold.canDisplayUpTo(sample) != -1) {
            throw new AssertionError("A bundled face is missing Cyrillic notice characters");
        }
        BufferedImage image = new BufferedImage(320, 52, BufferedImage.TYPE_INT_ARGB);
        Graphics2D graphics = image.createGraphics();
        try {
            graphics.setFont(semiBold);
            graphics.drawString(sample, 16, 20);
            graphics.setFont(regular);
            graphics.drawString(sample, 16, 40);
        } finally {
            graphics.dispose();
        }
        boolean hasInk = false;
        for (int y = 0; y < image.getHeight(); y++)
            for (int x = 0; x < image.getWidth(); x++)
                hasInk |= (image.getRGB(x, y) >>> 24) != 0;
        if (!hasInk) throw new AssertionError("Java rendered no text with the bundled fonts");
        System.out.println("Notice font contract passed: physical Roboto faces and Cyrillic rasterization.");
    }

    private static void expectFontFailure(Path directory, Properties style) throws Exception {
        try {
            PortableNoticeFonts.load(directory, style);
            throw new AssertionError("Missing or modified font did not disable the bundled mode");
        } catch (IOException expected) { }
    }

    private static void windowTitleContracts() {
        String property = "lanminecraft.window.title";
        String previous = System.getProperty(property);
        String display = "org/lwjgl/opengl/Display";
        byte[] source = fixture(display, "setTitle", "(Ljava/lang/String;)V", false);
        try {
            System.clearProperty(property);
            PortableNoticeWindowTransformer disabled = new PortableNoticeWindowTransformer();
            System.setProperty(property, "Pack title");
            PortableNoticeWindowTransformer enabled = new PortableNoticeWindowTransformer();
            if (disabled.transform(null, display, null, null, source) != null) {
                throw new AssertionError("A disabled launch acquired a window title hook");
            }
            System.clearProperty(property);
            if (enabled.transform(null, display, null, null, source) == null) {
                throw new AssertionError("Window title hook read the property during class loading");
            }
            if (enabled.transform(null, "java/lang/ClassLoader$1", null, null, null) != null) {
                throw new AssertionError("Window title hook touched a JVM class");
            }
        } finally {
            if (previous == null) System.clearProperty(property);
            else System.setProperty(property, previous);
        }
        System.out.println("Window title transformer reads its setting before class loading.");
    }

    private static void scaleContracts() {
        Properties values = new Properties();
        if (PortableNoticeHooks.parseScale(values) != 1) throw new AssertionError("Old snapshots need scale 1");
        values.setProperty("dpiScale", "1.5");
        if (PortableNoticeHooks.parseScale(values) != 1.5) throw new AssertionError("Monitor DPI was lost");
        for (String invalid : new String[] { "NaN", "Infinity", "-1", "0", "5", "invalid" }) {
            values.setProperty("dpiScale", invalid);
            if (PortableNoticeHooks.parseScale(values) != 1) throw new AssertionError("Invalid DPI accepted: " + invalid);
        }
        System.out.println("Monitor DPI contracts passed (legacy default, fractional DPI, invalid input).");
    }

    private static void snapshotContracts() {
        long now = 1800000000000L;
        Properties data = new Properties();
        data.setProperty("count", "1");
        data.setProperty("0.title", "Друг Оскар");
        data.setProperty("0.body", "Зашёл в сборку");
        data.setProperty("0.createdUnixMs", Long.toString(now - 100));
        PortableNoticeHooks.Notice[] parsed = PortableNoticeHooks.parse(data, now);
        if (parsed.length != 1 || !data.getProperty("0.title").equals(parsed[0].title)) {
            throw new AssertionError("Unicode notification was not preserved");
        }
        if (PortableNoticeHooks.parse(data, now + 7001).length != 0) throw new AssertionError("Notification did not expire");
        data.setProperty("0.createdUnixMs", Long.toString(now + 100));
        if (PortableNoticeHooks.parse(data, now).length != 1) throw new AssertionError("A clock tick of skew must not permanently drop the notice");
        data.setProperty("0.createdUnixMs", Long.toString(now + 2001));
        try {
            PortableNoticeHooks.parse(data, now);
            throw new AssertionError("Unbounded future timestamp accepted");
        } catch (IllegalArgumentException expected) { }
        data.setProperty("count", "4");
        try {
            PortableNoticeHooks.parse(data, now);
            throw new AssertionError("Unbounded snapshot was accepted");
        } catch (IllegalArgumentException expected) { }
        System.out.println("Snapshot contracts passed (Unicode, expiry, bounds).");
    }

    private static void audit(String name, String method, String signature, boolean nativeMethod) {
        byte[] source = fixture(name, method, signature, nativeMethod);
        byte[] changed = new PortableNoticeTransformer().transform(null, name, null, null, source);
        if (nativeMethod) {
            if (changed != null) throw new AssertionError("Native presentation cannot receive Java bytecode");
            return;
        }
        if (changed == null) throw new AssertionError("Presentation wrapper was not instrumented");
        final int[] hooks = { 0 };
        new ClassReader(changed).accept(new ClassVisitor(Opcodes.ASM9) {
            @Override public MethodVisitor visitMethod(int access, String methodName, String descriptor,
                                                        String signature, String[] exceptions) {
                return new MethodVisitor(Opcodes.ASM9) {
                    @Override public void visitMethodInsn(int opcode, String owner, String called,
                                                          String descriptor, boolean isInterface) {
                        if ("minecraft/portable/notice/PortableNoticeHooks".equals(owner) && "present".equals(called)) {
                            if (opcode != Opcodes.INVOKESTATIC || !"(Ljava/lang/Class;J)V".equals(descriptor)) {
                                throw new AssertionError("Presentation hook signature changed");
                            }
                            hooks[0]++;
                        }
                    }
                };
            }
        }, 0);
        if (hooks[0] != 1) throw new AssertionError("Expected one hook, found " + hooks[0]);
    }

    private static byte[] fixture(String name, String method, String signature, boolean nativeMethod) {
        ClassWriter writer = new ClassWriter(ClassWriter.COMPUTE_MAXS);
        writer.visit(Opcodes.V1_8, Opcodes.ACC_PUBLIC, name, null, "java/lang/Object", null);
        MethodVisitor target = writer.visitMethod(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC |
            (nativeMethod ? Opcodes.ACC_NATIVE : 0), method, signature, null, null);
        if (!nativeMethod) {
            target.visitCode();
            if (signature.endsWith("Z")) {
                target.visitInsn(Opcodes.ICONST_1);
                target.visitInsn(Opcodes.IRETURN);
            } else target.visitInsn(Opcodes.RETURN);
            target.visitMaxs(0, 0);
        }
        target.visitEnd();
        writer.visitEnd();
        return writer.toByteArray();
    }
}
