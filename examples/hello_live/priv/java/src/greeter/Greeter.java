package greeter;

public final class Greeter {
  private Greeter() {}

  public static String hello(String name) {
    return "Hello, " + name + "! I'm Java " + System.getProperty("java.version") + ".";
  }
}
