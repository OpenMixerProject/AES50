-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE
-- File         : <aes50_tdm_if_optimized.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
-- Version 1.0  : 2025-02-26 - First release
-- Version 1.1  : 2026-02-24 - Use two-dimensional arrays for tdm-data. Changed offsets. Optimized signal-pipeline.
--
-- Description  : Handles TDM-8 Interface (6x TDM8-in, 6x TDM8-out, 1xTDM8-in for aux-data, 1xTDM8-out for aux-data) for the AES50-IP.
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
use IEEE.NUMERIC_STD.ALL;

entity aes50_tdm_if_optimized is
port (
    clk100_i                        : in std_logic;
    rst_i                           : in std_logic;
    
    fs_mode_i                       : in std_logic_vector(1 downto 0);
    tdm8_i2s_mode_i                 : in std_logic;
    
    -- tdm if
    tdm_bclk_i                      : in std_logic;
    tdm_wclk_i                      : in std_logic;
    
    tdm_audio_i                     : in std_logic_vector(5 downto 0);
    tdm_audio_o                     : out std_logic_vector(5 downto 0);
    
    tdm_aux_i                       : in std_logic;
    tdm_aux_o                       : out std_logic;
    
    aes_rx_ok_i                     : in std_logic;
    enable_tx_i                     : in std_logic;
    
    -- FIFO interface to aes50-tx    
    audio_o                         : out std_logic_vector (23 downto 0);
    audio_ch0_marker_o              : out std_logic;
    aux_o                           : out std_logic_vector (15 downto 0);
    audio_out_wr_en_o               : out std_logic;
    aux_out_wr_en_o                 : out std_logic;
    
    -- FIFO interface to aes50-rx
    audio_i                         : in std_logic_vector(23 downto 0);
    audio_ch0_marker_i              : in std_logic;
    aux_i                           : in std_logic_vector(15 downto 0);
    audio_in_rd_en_o                : out std_logic;
    aux_in_rd_en_o                  : out std_logic;
    fifo_fill_count_audio_i         : in integer range 1056 - 1 downto 0;
    fifo_fill_count_aux_i           : in integer range 176 - 1 downto 0;
    
    audio_fifo_misalign_panic_o     : out std_logic;
    tdm_debug_o                     : out std_logic_vector(3 downto 0)
);
end aes50_tdm_if_optimized;

architecture rtl of aes50_tdm_if_optimized is
    type tdm_slot_array is array(0 to 7) of std_logic_vector(23 downto 0);
    type tdm_bus_array  is array(0 to 6) of tdm_slot_array;
    
    signal tdm_out_data     : tdm_bus_array;
    signal tdm_in_data      : tdm_bus_array;

    type tdm8_type is array(0 to 6) of std_logic_vector(31 downto 0);    
    signal tdm_out_shift    : tdm8_type;
    signal tdm_in_shift     : tdm8_type;

    -- i2s related signals
    signal i2s_out_data_l, i2s_out_data_r : std_logic_vector(23 downto 0);
    signal i2s_in_shift, i2s_out_shift   : std_logic_vector(31 downto 0);
    signal i2s_in_data_l, i2s_in_data_r   : std_logic_vector(23 downto 0);
    signal i2s_sample_finished           : std_logic;
    signal i2s_sample_finished_size      : integer range 31 downto 0;
    signal i2s_sample_in_l_temp          : std_logic_vector(23 downto 0);
    signal i2s_sample_out_r_temp         : std_logic_vector(23 downto 0);

    signal wclk_z, wclk_zz, wclk_old     : std_logic;
    signal wclk_sync_fetch_data          : std_logic;
    signal wclk_sync_store_data          : std_logic;
    signal wclk_sync_fetch_data_shift    : std_logic_vector(1 downto 0);
    signal wclk_sync_store_data_shift    : std_logic_vector(1 downto 0);

    signal bclk_shift                    : std_logic_vector(2 downto 0);
    signal bclk_counter                  : integer range 260 downto 0;

    signal shift_word_in_offset          : integer range 7 downto 0;
    signal shift_word_out_offset         : integer range 7 downto 0;
    signal shift_store_load              : std_logic;

    signal tdm_in_z, tdm_in_zz           : std_logic_vector(5 downto 0);
    signal data_in_z, data_in_zz         : std_logic;
    
    signal state_fifo_reader             : integer range 15 downto 0;
    signal sample_serdes_counter_out     : integer range 7 downto 0;
    signal serdes_counter_out            : integer range 7 downto 0;
    signal sample_aux_block_counter_out  : integer range 15 downto 0;
    signal aux_counter_out               : integer range 127 downto 0;

    signal state_fifo_writer             : integer range 15 downto 0;
    signal sample_serdes_counter_in      : integer range 7 downto 0;
    signal serdes_counter_in             : integer range 7 downto 0;
    signal tmp_sample                    : std_logic_vector(23 downto 0);

    signal tmp_aux_word                  : std_logic_vector(15 downto 0);
    signal tmp_aux_offset                : integer range 127 downto 0;
    signal tmp_aux_valid                 : std_logic;
    
    signal aux_ram_we                    : std_logic;
    signal aux_ram_di, aux_ram_do        : std_logic_vector(15 downto 0);
    signal aux_ram_addr                  : integer range 127 downto 0;

    signal debug_serdes_to_fifo_toggle, debug_fifo_to_serdes_process, 
           debug_serdes_rising_edge, debug_serdes_falling_edge : std_logic;

begin
	tdm_debug_o <= debug_serdes_to_fifo_toggle & debug_fifo_to_serdes_process & debug_serdes_rising_edge & debug_serdes_falling_edge;

	process(clk100_i)
	begin
		if rising_edge(clk100_i) then
			-- Timing f�r Bit 31 nach FrameSync (TDM8 Modus)
			shift_store_load <= '0';
			case bclk_counter is
				when 1*32+1 => shift_word_in_offset <= 7; shift_word_out_offset <= 6; shift_store_load <= '1';
				when 2*32+1 => shift_word_in_offset <= 6; shift_word_out_offset <= 5; shift_store_load <= '1';
				when 3*32+1 => shift_word_in_offset <= 5; shift_word_out_offset <= 4; shift_store_load <= '1';
				when 4*32+1 => shift_word_in_offset <= 4; shift_word_out_offset <= 3; shift_store_load <= '1';
				when 5*32+1 => shift_word_in_offset <= 3; shift_word_out_offset <= 2; shift_store_load <= '1';
				when 6*32+1 => shift_word_in_offset <= 2; shift_word_out_offset <= 1; shift_store_load <= '1';
				when 7*32+1 => shift_word_in_offset <= 1; shift_word_out_offset <= 0; shift_store_load <= '1';
				when 1      => shift_word_in_offset <= 0; shift_word_out_offset <= 7; shift_store_load <= '1';
				when others => null;
			end case;
		end if;
	end process;

	-- =============================================================
	-- FIFO WRITER (Data to FIFO)
	-- =============================================================
	process(clk100_i)
	begin
		if rising_edge(clk100_i) then
			wclk_sync_store_data_shift <= wclk_sync_store_data_shift(0) & wclk_sync_store_data;
			
			if (rst_i = '1' or enable_tx_i = '0') then
				state_fifo_writer <= 0;
				audio_out_wr_en_o <= '0';
				aux_out_wr_en_o <= '0';
				debug_serdes_to_fifo_toggle <= '0';
			else
				case state_fifo_writer is
					when 0 =>
						if wclk_sync_store_data_shift = "10" then
							state_fifo_writer <= 1;
							serdes_counter_in <= 0;
							sample_serdes_counter_in <= 0;
							debug_serdes_to_fifo_toggle <= '1';
						end if;

					when 1 =>
						tmp_sample <= tdm_in_data(serdes_counter_in)(sample_serdes_counter_in);
						state_fifo_writer <= 2;

					when 2 =>
						audio_o <= tmp_sample;
						audio_ch0_marker_o <= '1' when (serdes_counter_in = 0 and sample_serdes_counter_in = 0) else '0';
						audio_out_wr_en_o <= '1';
						state_fifo_writer <= 3;

					when 3 =>
						audio_out_wr_en_o <= '0';
						if sample_serdes_counter_in < 7 then
							sample_serdes_counter_in <= sample_serdes_counter_in + 1;
							state_fifo_writer <= 1;
						elsif serdes_counter_in < 5 then
							sample_serdes_counter_in <= 0;
							serdes_counter_in <= serdes_counter_in + 1;
							state_fifo_writer <= 1;
						else
							state_fifo_writer <= 4;
							sample_serdes_counter_in <= 0;
						end if;

					when 4 =>
						-- Aux Handling (from TDM-bus 6)
						tmp_sample     <= tdm_in_data(6)(sample_serdes_counter_in);
						state_fifo_writer <= 5;
					
					when 5 =>
						tmp_aux_word   <= tmp_sample(23 downto 8);
						tmp_aux_valid  <= tmp_sample(7);
						tmp_aux_offset <= to_integer(unsigned(tmp_sample(6 downto 0)));
						state_fifo_writer <= 6;

					when 6 =>
						if tmp_aux_valid = '1' and tmp_aux_offset <= 87 then
							aux_ram_we <= '1';
							aux_ram_di <= tmp_aux_word;
							aux_ram_addr <= tmp_aux_offset;
						end if;
						state_fifo_writer <= 7;

					when 7 =>
						aux_ram_we <= '0';
						if (tmp_aux_offset = 43 and fs_mode_i = "01") or (tmp_aux_offset = 87 and fs_mode_i = "00") then
							tmp_aux_offset <= 0;
							state_fifo_writer <= 8;
						else
							if sample_serdes_counter_in < 7 then
								sample_serdes_counter_in <= sample_serdes_counter_in + 1;
								state_fifo_writer <= 4;
							else
								state_fifo_writer <= 0;
								debug_serdes_to_fifo_toggle <= '0';
							end if;
						end if;

					when 8 =>
						aux_ram_addr <= tmp_aux_offset;
						state_fifo_writer <= 9;
					
					when 9 => state_fifo_writer <= 10; -- Stall
					
					when 10 =>
						aux_o <= aux_ram_do;
						aux_out_wr_en_o <= '1';
						state_fifo_writer <= 11;
					
					when 11 =>
						aux_out_wr_en_o <= '0';
						if (fs_mode_i="01" and tmp_aux_offset < 43) or (fs_mode_i="00" and tmp_aux_offset < 87) then
							tmp_aux_offset <= tmp_aux_offset + 1;
							state_fifo_writer <= 8;
						else
							state_fifo_writer <= 0;
							debug_serdes_to_fifo_toggle <= '0';
						end if;

					when others => state_fifo_writer <= 0;
				end case;
			end if;
		end if;
	end process;

	-- =============================================================
	-- FIFO READER (FIFO to Serdes)
	-- =============================================================
	process(clk100_i)
	begin
		if rising_edge(clk100_i) then
			wclk_sync_fetch_data_shift <= wclk_sync_fetch_data_shift(0) & wclk_sync_fetch_data;
			if (rst_i = '1' or aes_rx_ok_i = '0') then
				state_fifo_reader <= 0;
				audio_in_rd_en_o <= '0';
				aux_in_rd_en_o <= '0';
				audio_fifo_misalign_panic_o <= '0';
			else
				case state_fifo_reader is
					when 0 =>
						if wclk_sync_fetch_data_shift = "10" and 
						   ((fifo_fill_count_audio_i >= 288 and fifo_fill_count_aux_i >= 44 and fs_mode_i = "01") or 
							(fifo_fill_count_audio_i >= 528 and fifo_fill_count_aux_i >= 88 and fs_mode_i = "00")) then
							
							if audio_ch0_marker_i /= '1' then
								audio_fifo_misalign_panic_o <= '1';
							end if;
							state_fifo_reader <= 1;
							audio_in_rd_en_o <= '1';
							serdes_counter_out <= 0;
							sample_serdes_counter_out <= 0;
							debug_fifo_to_serdes_process <= '1';
						end if;

					when 1 =>
						audio_in_rd_en_o <= '0';
						state_fifo_reader <= 2;

					when 2 =>
						tdm_out_data(serdes_counter_out)(sample_serdes_counter_out) <= audio_i;
						if sample_serdes_counter_out < 7 then
							sample_serdes_counter_out <= sample_serdes_counter_out + 1;
							audio_in_rd_en_o <= '1';
							state_fifo_reader <= 1;
						elsif serdes_counter_out < 5 then
							sample_serdes_counter_out <= 0;
							serdes_counter_out <= serdes_counter_out + 1;
							audio_in_rd_en_o <= '1';
							state_fifo_reader <= 1;
						else
							state_fifo_reader <= 3;
						end if;

					when 3 =>
						aux_in_rd_en_o <= '1';
						sample_serdes_counter_out <= 0;
						state_fifo_reader <= 4;

					when 4 =>
						aux_in_rd_en_o <= '0';
						state_fifo_reader <= 5;

					when 5 =>
						tdm_out_data(6)(sample_serdes_counter_out) <= aux_i & "1" & std_logic_vector(to_unsigned(aux_counter_out,7));
						aux_counter_out <= aux_counter_out + 1;
						
						if (fs_mode_i="01" and sample_aux_block_counter_out < 5) or (fs_mode_i="00" and sample_aux_block_counter_out < 10) then
							if sample_serdes_counter_out < 7 then
								sample_serdes_counter_out <= sample_serdes_counter_out + 1;
								aux_in_rd_en_o <= '1';
								state_fifo_reader <= 4;
							else
								sample_aux_block_counter_out <= sample_aux_block_counter_out + 1;
								state_fifo_reader <= 6;
							end if;
						else
							if (fs_mode_i = "01" and sample_serdes_counter_out < 3) or (fs_mode_i = "00" and sample_serdes_counter_out < 7) then
								sample_serdes_counter_out <= sample_serdes_counter_out + 1;
								aux_in_rd_en_o <= '1';
								state_fifo_reader <= 4;
							else
								state_fifo_reader <= 0;
								debug_fifo_to_serdes_process <= '0';
							end if;
						end if;

					when 6 =>
						if wclk_sync_fetch_data_shift = "10" then
							state_fifo_reader <= 1;
							audio_in_rd_en_o <= '1';
							serdes_counter_out <= 0;
							sample_serdes_counter_out <= 0;
						end if;

					when others => state_fifo_reader <= 0;
				end case;
			end if;
		end if;
	end process;

	-- =============================================================
	-- TDM SERDES PHYSICAL PROCESS
	-- =============================================================
	process(clk100_i)
	begin
		if rising_edge(clk100_i) then
			if rst_i = '1' then
				bclk_counter <= 0;
				tdm_audio_o <= (others=>'0');
			else
				bclk_shift <= bclk_shift(1 downto 0) & tdm_bclk_i; -- regular bitclock
				--bclk_shift <= bclk_shift(1 downto 0) & (not tdm_bclk_i); -- invert bitclock if desired
				
				tdm_in_z <= tdm_audio_i; tdm_in_zz <= tdm_in_z;
				data_in_z <= tdm_aux_i; data_in_zz <= data_in_z;
				wclk_z <= tdm_wclk_i; wclk_zz <= wclk_z;

				-- RISING EDGE: Input Sampling
				if bclk_shift(2 downto 1) = "01" then
					if wclk_old = '0' and wclk_zz = '1' then
						bclk_counter <= 1;
					else
						bclk_counter <= bclk_counter + 1;
					end if;
					wclk_old <= wclk_zz;

					for i in 0 to 5 loop
						tdm_in_shift(i) <= tdm_in_shift(i)(30 downto 0) & tdm_in_zz(i);
					end loop;
					tdm_in_shift(6) <= tdm_in_shift(6)(30 downto 0) & data_in_zz;
				
				-- FALLING EDGE: Output & Internal Transfers
				elsif bclk_shift(2 downto 1) = "10" then
					if bclk_counter = 256 then wclk_sync_store_data <= '1';
					elsif bclk_counter = 224 then wclk_sync_fetch_data <= '1';
					else wclk_sync_fetch_data <= '0'; wclk_sync_store_data <= '0';
					end if;

					if shift_store_load = '1' then
						for i in 0 to 6 loop
							tdm_in_data(i)(shift_word_in_offset) <= tdm_in_shift(i)(31 downto 8);
							tdm_out_shift(i) <= tdm_out_data(i)(shift_word_out_offset)(22 downto 0) & "000000000";
							if i < 6 then
								tdm_audio_o(i) <= tdm_out_data(i)(shift_word_out_offset)(23);
							else
								tdm_aux_o <= tdm_out_data(6)(shift_word_out_offset)(23);
							end if;
						end loop;
					else
						-- Normal Shifting
						for i in 0 to 5 loop
							tdm_audio_o(i) <= tdm_out_shift(i)(31);
							tdm_out_shift(i) <= tdm_out_shift(i)(30 downto 0) & '0';
						end loop;
					end if;
				end if;
			end if;
		end if;
	end process;

	tdm_aux_ram : entity work.aes50_dual_port_bram (rtl)
		generic map( RAM_WIDTH => 16, RAM_DEPTH => 128 )
		port map(
			clka_i => clk100_i, clkb_i => clk100_i, ena_i => '1', enb_i => '0',
			wea_i => aux_ram_we, web_i => '0', addra_i => aux_ram_addr, addrb_i => 0,
			da_i => aux_ram_di, db_i => (others=>'0'), da_o => aux_ram_do, db_o => open
		);
end architecture;
