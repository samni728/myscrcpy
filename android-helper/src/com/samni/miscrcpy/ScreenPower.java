package com.samni.miscrcpy;
import java.lang.reflect.Method;

public final class ScreenPower {
  private static final String PREFIX = "MISCRCPY_SCREEN_POWER";
  public static void main(String[] args) {
    if (args.length != 1 || (!"off".equals(args[0]) && !"on".equals(args[0]))) {
      System.err.println(PREFIX + " INVALID_ARGUMENT"); System.exit(2); return;
    }
    try {
      Class<?> cls = Class.forName("android.view.SurfaceControl");
      Class<?> binder = Class.forName("android.os.IBinder");
      int mode = "off".equals(args[0]) ? 0 : 2;
      long[] physicalIds = (long[]) cls.getMethod("getPhysicalDisplayIds").invoke(null);
      if (physicalIds == null || physicalIds.length == 0) throw new IllegalStateException("No physical display");
      Method tokenMethod = cls.getMethod("getPhysicalDisplayToken", Long.TYPE);
      Method setPower = cls.getMethod("setDisplayPowerMode", binder, Integer.TYPE);
      for (long id : physicalIds) {
        Object token=tokenMethod.invoke(null,id);
        if (token == null) throw new IllegalStateException("display token null");
        setPower.invoke(null,token,mode);
      }
      System.out.println(PREFIX + " " + args[0] + " OK count=" + physicalIds.length);
    } catch (Throwable t) {
      System.err.println(PREFIX + " " + args[0] + " FAILED " + t.toString());
      t.printStackTrace();
      System.exit(3);
    }
  }
}
