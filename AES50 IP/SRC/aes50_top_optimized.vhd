-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE
-- File         : <aes50_top_optimized.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
-- Created      : <2025-02-26>
--
-- Description  : Top-Module for the AES50 IP Core
--
-- License      : GNU General Public License v3.0 or later (GPL-3.0-or-later)
--
-- This file is part of the AES50 VHDL IP-CORE.
--
-- The AES50 VHDL IP-CORE is free software: you can redistribute it and/or
-- modify it under the terms of the GNU General Public License as published
-- by the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- The AES50 VHDL IP-CORE is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program. If not, see <https://www.gnu.org/licenses/>.
-- ===========================================================================


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

entity aes50_top_optimized is
port (
    -- clk and reset
    clk50_i                             : in  std_logic; 
    clk100_i                            : in  std_logic; 
    rst_i                               : in  std_logic; 
    
    -- samplerate and operation mode
    fs_mode_i                           : in std_logic_vector(1 downto 0);
    sys_mode_i                          : in std_logic_vector(1 downto 0);
    tdm8_i2s_mode_i                     : in std_logic;
    
    -- connection to phy
    rmii_crs_dv_i                       : in  std_logic;        
    rmii_rxd_i                          : in std_logic_vector(1 downto 0);  
    rmii_tx_en_o                        : out std_logic;       
    rmii_txd_o                          : out std_logic_vector(1 downto 0);   
    phy_rst_n_o                         : out std_logic;

    -- connection to clk transceivers
    aes50_clk_a_rx_i                    : in  std_logic;
    aes50_clk_a_tx_o                    : out std_logic;
    aes50_clk_a_tx_en_o                 : out std_logic;
    aes50_clk_b_rx_i                    : in  std_logic; 
    aes50_clk_b_tx_o                    : out std_logic;
    aes50_clk_b_tx_en_o                 : out std_logic;

    -- interface to external PLL
    clk_1024xfs_from_pll_i              : in  std_logic; 
    pll_lock_n_i                        : in  std_logic; 
    clk_to_pll_o                        : out std_logic;
    pll_mult_value_o                    : out std_logic_vector(31 downto 0);
    pll_init_busy_i                     : in  std_logic; 
    
    -- tdm/i2s clk interface
    mclk_o                              : out std_logic;
    wclk_o                              : out std_logic;
    bclk_o                              : out std_logic;
    wclk_readback_i                     : in  std_logic; 
    bclk_readback_i                     : in  std_logic; 
    wclk_out_en_o                       : out std_logic;
    bclk_out_en_o                       : out std_logic;
    tdm_i                               : in std_logic_vector(6 downto 0);
    tdm_o                               : out std_logic_vector(6 downto 0);
    
    i2s_i                               : in std_logic;
    i2s_o                               : out std_logic;
    aes_ok_o                            : out std_logic;
    
    -- debug & variables
    dbg_o                               : out std_logic_vector(7 downto 0);
    debug_out_signal_pulse_len_i        : in std_logic_vector(19 downto 0);
    first_transmit_start_counter_48k_i  : in std_logic_vector(22 downto 0);
    first_transmit_start_counter_44k1_i : in std_logic_vector(22 downto 0);
    wd_aes_clk_timeout_i                : in std_logic_vector(5 downto 0);
    wd_aes_rx_dv_timeout_i              : in std_logic_vector(14 downto 0);
    mdix_timer_1ms_reference_i          : in std_logic_vector(16 downto 0);
    aes_clk_ok_counter_reference_i      : in std_logic_vector(19 downto 0);
    mult_clk625_48k_i                   : in std_logic_vector(31 downto 0);
    mult_clk625_44k1_i                  : in std_logic_vector(31 downto 0)
);
end aes50_top_optimized;

architecture rtl of aes50_top_optimized is

    -- Reset & Health
    signal phy_rst_cnt              : integer range 100000 downto 0;
    signal audio_clock_ok           : std_logic;
    signal aes_rx_ok                : std_logic;
    signal audio_logic_reset        : std_logic;
    signal aes_rx_rst               : std_logic;
    signal aes_tx_rst               : std_logic;
    signal clk_mgr_rst              : std_logic;
    signal eth_rst                  : std_logic;
    signal eth_rst_50M_z, eth_rst_50M_zz : std_logic;

    -- Scheduling
    signal first_transmit_start_counter : integer range 5000000 downto 0;
    signal first_transmit_start_active  : std_logic;
    signal enable_tx_assm_start         : std_logic;

    -- Internal Connectivity
    signal mclk_internal            : std_logic;
    signal tdm_internal_i           : std_logic_vector(6 downto 0);
    signal tdm_internal_o           : std_logic_vector(6 downto 0);
    signal txd_data_int, rxd_data_int : std_logic_vector(1 downto 0);
    signal txd_en_int, rxd_en_int   : std_logic;

    -- PHY Stream Interface
    signal phy_tx_data, phy_rx_data : std_logic_vector(7 downto 0);
    signal phy_tx_eof, phy_tx_valid, phy_tx_ready : std_logic;
    signal phy_rx_sof, phy_rx_eof, phy_rx_valid  : std_logic;

    -- FIFO Interconnects
    signal fifo_aes_to_tdm_audio_data   : std_logic_vector(23 downto 0);
    signal fifo_aes_to_tdm_audio_ch0    : std_logic;
    signal fifo_aes_to_tdm_aux_data     : std_logic_vector(15 downto 0);
    signal fifo_aes_to_tdm_audio_rd     : std_logic;
    signal fifo_aes_to_tdm_aux_rd       : std_logic;
    signal fifo_aes_to_tdm_audio_cnt    : integer range 0 to 1055;
    signal fifo_aes_to_tdm_aux_cnt      : integer range 0 to 175;
    signal fifo_aes_to_tdm_panic        : std_logic;

    signal fifo_tdm_to_aes_audio_data   : std_logic_vector(23 downto 0);
    signal fifo_tdm_to_aes_audio_ch0    : std_logic;
    signal fifo_tdm_to_aes_aux_data     : std_logic_vector(15 downto 0);
    signal fifo_tdm_to_aes_audio_wr     : std_logic;
    signal fifo_tdm_to_aes_aux_wr       : std_logic;
    signal fifo_tdm_to_aes_panic        : std_logic;

    -- ASSM / Debug
    signal assm_remote, assm_self_gen   : std_logic;
    signal assm_active_edge             : std_logic_vector(1 downto 0);
    signal assm_tx_is_active            : std_logic;
    signal assm_rx_is_active            : std_logic;
    signal assm_tx_active_edge          : std_logic_vector(1 downto 0);
    signal assm_rx_active_edge          : std_logic_vector(1 downto 0);
    
    -- Debug Pulse Generator Signals (vereinfacht)
    signal dbg_pulse_tx, dbg_pulse_rx, dbg_pulse_clk : std_logic;

begin

    -- Static assignments
    wclk_out_en_o <= '1' when (sys_mode_i = "00" or sys_mode_i = "01") else '0';
    bclk_out_en_o <= '1' when (sys_mode_i = "00" or sys_mode_i = "01") else '0';
    aes_ok_o      <= audio_clock_ok;
    mclk_o        <= mclk_internal;
    
    -- TDM / I2S Mapping
    tdm_o <= tdm_internal_o when (tdm8_i2s_mode_i = '0') else (others => '0');
    i2s_o <= tdm_internal_o(0) when (tdm8_i2s_mode_i = '1') else '0';
    tdm_internal_i <= tdm_i when (tdm8_i2s_mode_i = '0') else ("000000" & i2s_i);

    -- RMII Passthrough
    rxd_data_int <= rmii_rxd_i;
    rxd_en_int   <= rmii_crs_dv_i;
    rmii_txd_o   <= txd_data_int;
    rmii_tx_en_o <= txd_en_int;

    -- RESET CONTROLLER (Core Clock)
    process(clk100_i)
    begin
        if rising_edge(clk100_i) then
            if (rst_i = '1' or fifo_tdm_to_aes_panic = '1' or fifo_aes_to_tdm_panic = '1') then
                phy_rst_cnt       <= 100000;
                phy_rst_n_o       <= '0';
                audio_logic_reset <= '1';
                eth_rst           <= '1';
                aes_rx_rst        <= '1';
                clk_mgr_rst       <= '1';
                aes_tx_rst        <= '1';
            else
                -- PHY Reset Timer
                if phy_rst_cnt > 0 then
                    phy_rst_cnt <= phy_rst_cnt - 1;
                else
                    phy_rst_n_o <= '1';
                end if;

                if pll_init_busy_i = '1' or phy_rst_cnt > 0 then
                    audio_logic_reset <= '1';
                    eth_rst           <= '1';
                    aes_rx_rst        <= '1';
                    clk_mgr_rst       <= '1';
                    aes_tx_rst        <= '1';
                else
                    clk_mgr_rst       <= '0';
                    audio_logic_reset <= '0';
                    eth_rst           <= '0';
                    aes_tx_rst        <= not enable_tx_assm_start;
                    aes_rx_rst        <= not aes_rx_ok;
                end if;
            end if;
        end if;
    end process;

    -- Synchronize reset to Ethernet Clock Domain
    process(clk50_i)
    begin
        if rising_edge(clk50_i) then
            eth_rst_50M_z  <= eth_rst;
            eth_rst_50M_zz <= eth_rst_50M_z;
        end if;
    end process;

    -- TX SCHEDULER & ASSM MONITOR
    process(clk100_i)
    begin
        if rising_edge(clk100_i) then
            if rst_i = '1' then
                enable_tx_assm_start <= '0';
                first_transmit_start_active <= '0';
            else
                -- Edge Detection for ASSM Signals
                if sys_mode_i = "00" then
                    assm_active_edge <= assm_active_edge(0) & assm_remote;
                else
                    assm_active_edge <= assm_active_edge(0) & assm_self_gen;
                end if;
                
                -- Wait for stable clock before starting transmission
                if audio_clock_ok = '0' then
                    if fs_mode_i = "01" then 
                        first_transmit_start_counter <= to_integer(unsigned(first_transmit_start_counter_48k_i));
                    else
                        first_transmit_start_counter <= to_integer(unsigned(first_transmit_start_counter_44k1_i));
                    end if;
                    first_transmit_start_active <= '0';
                    enable_tx_assm_start        <= '0';
                else
                    -- Trigger scheduling on ASSM edge
                    if assm_active_edge = "01" then
                        first_transmit_start_active <= '1';
                    end if;

                    if first_transmit_start_active = '1' then
                        if first_transmit_start_counter > 0 then
                            first_transmit_start_counter <= first_transmit_start_counter - 1;
                        else
                            enable_tx_assm_start <= '1';
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

-- INSTANTIATIONS (Clockmanager, TDM IF, RMII, AES-TX/RX)

clkmanager: entity work.aes50_clockmanager(rtl)
	port map (
		clk100_i                      => clk100_i,
		rst_i                         => clk_mgr_rst,
		sys_mode_i                    => sys_mode_i,
		fs_mode_i                     => fs_mode_i,
		clk_1024xfs_from_pll_i        => clk_1024xfs_from_pll_i,
		pll_lock_n_i                  => pll_lock_n_i,
		clk_to_pll_o                  => clk_to_pll_o,
		pll_mult_value_o              => pll_mult_value_o,
		mclk_o                        => mclk_internal,
		wclk_o                        => wclk_o,
		bclk_o                        => bclk_o,
		wclk_readback_i               => wclk_readback_i,
		bclk_readback_i               => bclk_readback_i,
		aes50_clk_a_rx_i              => aes50_clk_a_rx_i,
		aes50_clk_a_tx_o              => aes50_clk_a_tx_o,
		assm_self_generated_o         => assm_self_gen,
		assm_remote_o                 => assm_remote,
		clock_health_good_o           => audio_clock_ok,
		eth_rx_dv_watchdog_i          => rxd_en_int,
		eth_rx_consider_good_o        => aes_rx_ok,
		wd_aes_clk_timeout_i          => wd_aes_clk_timeout_i,
		wd_aes_rx_dv_timeout_i        => wd_aes_rx_dv_timeout_i,
		mdix_timer_1ms_reference_i    => mdix_timer_1ms_reference_i,
		aes_clk_ok_counter_reference_i => aes_clk_ok_counter_reference_i,
		mult_clk625_48k_i             => mult_clk625_48k_i,
		mult_clk625_44k1_i            => mult_clk625_44k1_i,
		aes50_clk_a_tx_en_o           => aes50_clk_a_tx_en_o,
		aes50_clk_b_rx_i              => aes50_clk_b_rx_i,
		aes50_clk_b_tx_o              => aes50_clk_b_tx_o,
		aes50_clk_b_tx_en_o           => aes50_clk_b_tx_en_o,
		tdm8_i2s_mode_i               => '0'
	);

    tdm_if_inst : entity work.aes50_tdm_if(rtl)
        port map (
            clk100_i => clk100_i, rst_i => audio_logic_reset, fs_mode_i => fs_mode_i, tdm8_i2s_mode_i => tdm8_i2s_mode_i,
            tdm_bclk_i => bclk_readback_i, tdm_wclk_i => wclk_readback_i,
            tdm_audio_i => tdm_internal_i(5 downto 0), tdm_audio_o => tdm_internal_o(5 downto 0),
            tdm_aux_i => tdm_internal_i(6), tdm_aux_o => tdm_internal_o(6),
            aes_rx_ok_i => aes_rx_ok, enable_tx_i => enable_tx_assm_start,
            audio_o => fifo_tdm_to_aes_audio_data, audio_ch0_marker_o => fifo_tdm_to_aes_audio_ch0,
            aux_o => fifo_tdm_to_aes_aux_data, audio_out_wr_en_o => fifo_tdm_to_aes_audio_wr,
            aux_out_wr_en_o => fifo_tdm_to_aes_aux_wr,
            audio_i => fifo_aes_to_tdm_audio_data, audio_ch0_marker_i => fifo_aes_to_tdm_audio_ch0,
            aux_i => fifo_aes_to_tdm_aux_data, audio_in_rd_en_o => fifo_aes_to_tdm_audio_rd,
            aux_in_rd_en_o => fifo_aes_to_tdm_aux_rd, fifo_fill_count_audio_i => fifo_aes_to_tdm_audio_cnt,
            fifo_fill_count_aux_i => fifo_aes_to_tdm_aux_cnt, audio_fifo_misalign_panic_o => fifo_aes_to_tdm_panic
        );

    rmii_inst : entity work.aes50_rmii_transceiver(rtl)
        port map (
            clk50_i => clk50_i, rst_i => eth_rst_50M_zz, rmii_crs_dv_i => rxd_en_int, rmii_rxd_i => rxd_data_int,
            rmii_tx_en_o => txd_en_int, rmii_txd_o => txd_data_int, eth_rx_data_o => phy_rx_data,
            eth_rx_sof_o => phy_rx_sof, eth_rx_eof_o => phy_rx_eof, eth_rx_valid_o => phy_rx_valid,
            eth_tx_data_i => phy_tx_data, eth_tx_eof_i => phy_tx_eof, eth_tx_valid_i => phy_tx_valid, eth_tx_ready_o => phy_tx_ready
        );

    aes_tx_inst : entity work.aes50_tx(rtl)
        port map (
            clk100_core_i => clk100_i, clk50_ethernet_i => clk50_i, rst_i => aes_tx_rst, fs_mode_i => fs_mode_i,
            assm_is_active_o => assm_tx_is_active, audio_i => fifo_tdm_to_aes_audio_data,
            audio_ch0_marker_i => fifo_tdm_to_aes_audio_ch0, aux_i => fifo_tdm_to_aes_aux_data,
            audio_in_wr_en_i => fifo_tdm_to_aes_audio_wr, aux_in_wr_en_i => fifo_tdm_to_aes_aux_wr,
            audio_fifo_misalign_panic_o => fifo_tdm_to_aes_panic, phy_tx_data_o => phy_tx_data,
            phy_tx_eof_o => phy_tx_eof, phy_tx_valid_o => phy_tx_valid, phy_tx_ready_i => phy_tx_ready
        );

    aes_rx_inst : entity work.aes50_rx(rtl)
        port map (
            clk100_core_i => clk100_i, clk50_ethernet_i => clk50_i, rst_i => aes_rx_rst, fs_mode_i => fs_mode_i,
            assm_detect_o => assm_rx_is_active, audio_o => fifo_aes_to_tdm_audio_data,
            audio_ch0_marker_o => fifo_aes_to_tdm_audio_ch0, aux_o => fifo_aes_to_tdm_aux_data,
            audio_out_rd_en_i => fifo_aes_to_tdm_audio_rd, aux_out_rd_en_i => fifo_aes_to_tdm_aux_rd,
            fifo_fill_count_audio_o => fifo_aes_to_tdm_audio_cnt, fifo_fill_count_aux_o => fifo_aes_to_tdm_aux_cnt,
            eth_rx_data_i => phy_rx_data, eth_rx_sof_i => phy_rx_sof, eth_rx_eof_i => phy_rx_eof,
            eth_rx_valid_i => phy_rx_valid, eth_rx_dv_i => rxd_en_int
        );

end architecture;
