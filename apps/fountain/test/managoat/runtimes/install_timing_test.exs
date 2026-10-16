defmodule Managoat.Runtimes.InstallTimingTest do
  use ExUnit.Case, async: true

  alias Managoat.Runtimes.InstallTiming

  test "reports fixed numeric phases and maxima across parallel download attempts" do
    attributes =
      InstallTiming.attributes("""
      __MANAGOAT_INSTALL__ cache_hit 1
      __MANAGOAT_INSTALL__ cache_hit 0
      __MANAGOAT_INSTALL__ lock_wait 12 10
      __MANAGOAT_INSTALL__ manifest 3100 3100
      __MANAGOAT_DOWNLOAD__ 0.001 0.020 0.060 0.200 2.500 1000
      __MANAGOAT_DOWNLOAD__ 0.002 0.030 0.050 0.100 1.500 2000
      """)

    assert attributes == %{
             "install_cache_hit" => 0,
             "install_lock_wait_ms" => 12,
             "install_manifest_ms" => 3100,
             "install_clock_skew_max_ms" => 2,
             "install_clock_checked" => 1,
             "install_timing_suspect" => 0,
             "download_attempts" => 2,
             "download_dns_max_ms" => 2.0,
             "download_connect_max_ms" => 30.0,
             "download_tls_max_ms" => 60.0,
             "download_first_byte_max_ms" => 200.0,
             "download_total_max_ms" => 2500.0,
             "download_bytes_max" => 2000.0
           }
  end

  test "a cached install reports no timing signal, having timed nothing" do
    assert InstallTiming.attributes("__MANAGOAT_INSTALL__ cache_hit 1\n") ==
             %{"install_cache_hit" => 1}
  end

  test "an installer with no monotonic clock records the phase without a cross-check" do
    attributes =
      InstallTiming.attributes("""
      __MANAGOAT_INSTALL__ manifest 3100 -
      __MANAGOAT_INSTALL__ link 4
      """)

    assert attributes == %{
             "install_manifest_ms" => 3100,
             "install_link_ms" => 4,
             "install_clock_checked" => 0,
             "install_timing_suspect" => 0
           }

    refute Map.has_key?(attributes, "install_clock_skew_max_ms")
  end

  test "a checked phase does not hide an unchecked phase in either order" do
    for lines <- [
          ["manifest 3100 3100", "link 4 -"],
          ["link 4", "manifest 3100 3100"]
        ] do
      attrs =
        InstallTiming.attributes(Enum.map_join(lines, "\n", &("__MANAGOAT_INSTALL__ " <> &1)))

      assert attrs["install_clock_checked"] == 0
      assert attrs["install_timing_suspect"] == 0
      assert attrs["install_clock_skew_max_ms"] == 0
    end
  end

  test "a negative monotonic duration cannot certify a phase" do
    attrs = InstallTiming.attributes("__MANAGOAT_INSTALL__ link 0 -1\n")
    assert attrs["install_clock_checked"] == 0
    assert attrs["install_timing_suspect"] == 1
    assert attrs["install_link_ms"] == 0
  end

  # The bug this signal exists for: a phase measured against a clock that moved
  # keeps its value and says so, because a dropped sample is indistinguishable
  # from one that was never taken (#2908).
  test "a phase that disagrees with its monotonic elapsed is kept and flagged" do
    attributes =
      InstallTiming.attributes("""
      __MANAGOAT_INSTALL__ lock_wait 11 10
      __MANAGOAT_INSTALL__ manifest 7316 6420
      """)

    assert attributes == %{
             "install_lock_wait_ms" => 11,
             "install_manifest_ms" => 7316,
             "install_clock_skew_max_ms" => 896,
             "install_clock_checked" => 1,
             "install_timing_suspect" => 1
           }
  end

  test "a negative or over-deadline phase is kept and flagged, not discarded" do
    assert InstallTiming.attributes("__MANAGOAT_INSTALL__ manifest -884 10\n") ==
             %{
               "install_manifest_ms" => -884,
               "install_clock_skew_max_ms" => 894,
               "install_clock_checked" => 1,
               "install_timing_suspect" => 1
             }

    assert InstallTiming.attributes("__MANAGOAT_INSTALL__ npm 180001\n") ==
             %{
               "install_npm_ms" => 180_001,
               "install_timing_suspect" => 1,
               "install_clock_checked" => 0
             }
  end

  test "disagreement within the monotonic clock's own resolution is not flagged" do
    attributes =
      InstallTiming.attributes("""
      __MANAGOAT_INSTALL__ link 2 0
      __MANAGOAT_INSTALL__ finalize 1007 1050
      """)

    assert attributes["install_timing_suspect"] == 0
    assert attributes["install_clock_skew_max_ms"] == 43
  end

  test "ignores arbitrary output, unknown fields and partial records" do
    assert %{} ==
             InstallTiming.attributes("""
             proxy=https://user:secret@example.test
             __MANAGOAT_INSTALL__ secret 123
             __MANAGOAT_INSTALL__ manifest
             __MANAGOAT_DOWNLOAD__ 0 0 0 0 1 https://secret@example.test
             __MANAGOAT_DOWNLOAD__ 0 0 0 0 1
             __MANAGOAT_DOWNLOAD__ 0 0 0 0 -1 1
             """)
  end

  test "a phase too large to be a measurement is refused, and says so" do
    assert InstallTiming.attributes("""
           __MANAGOAT_INSTALL__ manifest 999999999999999999999
           __MANAGOAT_INSTALL__ manifest 3ms
           __MANAGOAT_INSTALL__ link 4 notanumber
           """) == %{
             "install_link_ms" => 4,
             "install_timing_suspect" => 1,
             "install_clock_checked" => 0
           }
  end
end
