package com.maxduke.guoguo_mobile;

import java.util.ArrayList;
import java.util.List;

/** Keep legacy SurfaceTexture video on the OpenGL renderer for television GPUs. */
public final class TelevisionRendererPolicy {
    private TelevisionRendererPolicy() {}

    public static String[] arguments(String[] current, boolean television) {
        if (!television) return current.clone();
        List<String> result = new ArrayList<>();
        for (String argument : current) {
            if (!argument.equals("--enable-impeller")
                    && !argument.startsWith("--enable-impeller=")) {
                result.add(argument);
            }
        }
        result.add("--enable-impeller=false");
        return result.toArray(new String[0]);
    }
}
