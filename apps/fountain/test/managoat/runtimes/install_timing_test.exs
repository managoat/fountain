defmodule Managoat.Runtimes.InstallTimingTest do
  use ExUnit.Case, async: true

  alias Managoat.Runtimes.InstallTiming

  test "bundle phases are kept, and removed installers' records are not" do
    attrs =
      InstallTiming.attributes("""
      __MANAGOAT_INSTALL__ cache_hit 0
      __MANAGOAT_INSTALL__ lock_wait 12 10
      __MANAGOAT_INSTALL__ image_probe 250 250
      __MANAGOAT_INSTALL__ bundle_verify 10 10
      __MANAGOAT_INSTALL__ bundle_extract 280 280
      __MANAGOAT_INSTALL__ bundle_hit 1
      __MANAGOAT_INSTALL__ bundle 900 900
      __MANAGOAT_INSTALL__ manifest 3100 3100
      __MANAGOAT_INSTALL__ npm 9000 9000
      __MANAGOAT_DOWNLOAD__ 0.001 0.020 0.060 0.200 2.500 1000 1
      __MANAGOAT_DOWNLOAD_RESULT__ 200 200 0 2
      """)

    assert attrs == %{
             "install_cache_hit" => 0,
             "install_lock_wait_ms" => 12,
             "install_image_probe_ms" => 250,
             "install_bundle_extract_ms" => 280,
             "install_clock_skew_max_ms" => 2,
             "install_clock_checked" => 1,
             "install_timing_suspect" => 0
           }
  end

  test "a finalize subphase remains separate and cross-checks its clock" do
    attrs =
      InstallTiming.attributes("""
      __MANAGOAT_INSTALL__ node_wait 800 800
      __MANAGOAT_INSTALL__ finalize 1007 1010
      """)

    assert attrs["install_node_wait_ms"] == 800
    assert attrs["install_finalize_ms"] == 1007
    assert attrs["install_clock_checked"] == 1
    assert attrs["install_timing_suspect"] == 0
    assert attrs["install_clock_skew_max_ms"] == 3
  end

  test "a cached install reports no timing signal, having timed nothing" do
    assert InstallTiming.attributes("__MANAGOAT_INSTALL__ cache_hit 1\n") ==
             %{"install_cache_hit" => 1}
  end

  test "an installer with no monotonic clock records the phase without a cross-check" do
    attributes =
      InstallTiming.attributes("""
      __MANAGOAT_INSTALL__ bundle_extract 3100 -
      __MANAGOAT_INSTALL__ link 4
      """)

    assert attributes == %{
             "install_bundle_extract_ms" => 3100,
             "install_link_ms" => 4,
             "install_clock_checked" => 0,
             "install_timing_suspect" => 0
           }

    refute Map.has_key?(attributes, "install_clock_skew_max_ms")
  end

  test "a checked phase does not hide an unchecked phase in either order" do
    for lines <- [
          ["bundle_extract 3100 3100", "link 4 -"],
          ["link 4", "bundle_extract 3100 3100"]
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
      __MANAGOAT_INSTALL__ bundle_extract 7316 6420
      """)

    assert attributes == %{
             "install_lock_wait_ms" => 11,
             "install_bundle_extract_ms" => 7316,
             "install_clock_skew_max_ms" => 896,
             "install_clock_checked" => 1,
             "install_timing_suspect" => 1
           }
  end

  test "a negative or over-deadline phase is kept and flagged, not discarded" do
    assert InstallTiming.attributes("__MANAGOAT_INSTALL__ bundle_extract -884 10\n") ==
             %{
               "install_bundle_extract_ms" => -884,
               "install_clock_skew_max_ms" => 894,
               "install_clock_checked" => 1,
               "install_timing_suspect" => 1
             }

    assert InstallTiming.attributes("__MANAGOAT_INSTALL__ bundle_extract 180001\n") ==
             %{
               "install_bundle_extract_ms" => 180_001,
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
             __MANAGOAT_INSTALL__ bundle_extract
             __MANAGOAT_INSTALL__ cache_hit secret
             """)
  end

  test "a phase too large to be a measurement is refused, and says so" do
    assert InstallTiming.attributes("""
           __MANAGOAT_INSTALL__ bundle_extract 999999999999999999999
           __MANAGOAT_INSTALL__ bundle_extract 3ms
           __MANAGOAT_INSTALL__ link 4 notanumber
           """) == %{
             "install_link_ms" => 4,
             "install_timing_suspect" => 1,
             "install_clock_checked" => 0
           }
  end
end
