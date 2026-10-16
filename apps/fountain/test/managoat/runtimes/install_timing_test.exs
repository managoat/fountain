defmodule Managoat.Runtimes.InstallTimingTest do
  use ExUnit.Case, async: true

  alias Managoat.Runtimes.InstallTiming

  test "reports fixed numeric phases and maxima across parallel download attempts" do
    attributes =
      InstallTiming.attributes("""
      __MANAGOAT_INSTALL__ cache_hit 1
      __MANAGOAT_INSTALL__ cache_hit 0
      __MANAGOAT_INSTALL__ lock_wait 12
      __MANAGOAT_INSTALL__ manifest 3100
      __MANAGOAT_DOWNLOAD__ 0.001 0.020 0.060 0.200 2.500 1000
      __MANAGOAT_DOWNLOAD__ 0.002 0.030 0.050 0.100 1.500 2000
      """)

    assert attributes == %{
             "install_cache_hit" => 0,
             "install_lock_wait_ms" => 12,
             "install_manifest_ms" => 3100,
             "download_attempts" => 2,
             "download_dns_max_ms" => 2.0,
             "download_connect_max_ms" => 30.0,
             "download_tls_max_ms" => 60.0,
             "download_first_byte_max_ms" => 200.0,
             "download_total_max_ms" => 2500.0,
             "download_bytes_max" => 2000.0
           }
  end

  test "ignores arbitrary output, unknown fields, invalid numbers and partial records" do
    assert %{} ==
             InstallTiming.attributes("""
             proxy=https://user:secret@example.test
             __MANAGOAT_INSTALL__ secret 123
             __MANAGOAT_INSTALL__ manifest -1
             __MANAGOAT_INSTALL__ manifest 999999999999999999999
             __MANAGOAT_INSTALL__ manifest 3ms
             __MANAGOAT_DOWNLOAD__ 0 0 0 0 1 https://secret@example.test
             __MANAGOAT_DOWNLOAD__ 0 0 0 0 1
             __MANAGOAT_DOWNLOAD__ 0 0 0 0 -1 1
             """)
  end
end
