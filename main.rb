require "rubygems"
gem "ruby-processing"
require "ruby-processing"
require "nes"
require "debugger"
require "palette"
require "constants"

include_class "javax.swing.JFrame"
include_class "javax.swing.JFileChooser"
include_class "java.lang.System"

module Processing
  SKETCH_PATH = "./"
end

class Main < Processing::App
  
  attr_accessor :nes
  
  include Palette
  include Constants
  
  CANVAS_X=100
  CANVAS_Y=0
  CANVAS_W=256
  CANVAS_H=240

  # Buttons
  BTN_PANEL_W=100
  BTN_PANEL_H=241

  LOAD_BTN_X=5
  LOAD_BTN_Y=10
  LOAD_BTN_H=90
  LOAD_BTN_W=90
  LOAD_BTN_IMG="icons/load.jpg"

  PWR_BTN_X=10
  PWR_BTN_Y=105
  PWR_BTN_H=40
  PWR_BTN_W=80
  PWR_BTN_IMG="icons/power.jpg"

  RESET_BTN_X=10
  RESET_BTN_Y=150
  RESET_BTN_H=40
  RESET_BTN_W=80
  RESET_BTN_IMG="icons/reset.jpg"

  DEBUG_LABEL_X=5
  DEBUG_LABEL_Y=225
  DEBUG_LABEL_SIZE=17

  DEBUG_BTN_X=65
  DEBUG_BTN_Y=205
  DEBUG_BTN_W=25
  DEBUG_BTN_H=25
  DEBUG_BTN_UNCHECKED_IMG="icons/checkbox-unchecked.jpg"
  DEBUG_BTN_CHECKED_IMG="icons/checkbox-checked.jpg"
  

  def setup
    @title = "RubyNES"
    
    size 356, 241, P2D

    # Control Panel
    fill 0xAA, 0xAA, 0xAA
    rect 0, 0, BTN_PANEL_W, BTN_PANEL_H

    load = loadImage LOAD_BTN_IMG
    image load, LOAD_BTN_X, LOAD_BTN_Y, LOAD_BTN_W, LOAD_BTN_H

    power = loadImage PWR_BTN_IMG
    image power, PWR_BTN_X, PWR_BTN_Y, PWR_BTN_W, PWR_BTN_H

    reset = loadImage RESET_BTN_IMG
    image reset, RESET_BTN_X, RESET_BTN_Y, RESET_BTN_W, RESET_BTN_H

    debug = loadImage DEBUG_BTN_UNCHECKED_IMG
    image debug, DEBUG_BTN_X, DEBUG_BTN_Y, DEBUG_BTN_W, DEBUG_BTN_H

    debug_font = createFont "Arial", DEBUG_LABEL_SIZE
    fill 0, 0, 0
    textFont debug_font
    text "Debug? ", DEBUG_LABEL_X, DEBUG_LABEL_Y
    
    # Now initialize the actual NES emulator
    @nes = NES.new
    
    # 1/30 of a second, NTSC refresh rate.
    frameRate 30
    
  end
  
  def draw
    if @nes.is_power_on?
      @nes.run_one_frame
    
      repaint
    end
  end
  
  def repaint
    ppu = @nes.ppu

    # I think the preferred method to do this is using an image buffer, see how in the ruby-processing samples
    loadPixels
    ppu.screen_buffer.each_index { |scanline_index|
      if (scanline_index != 0) # Scanline 1 in the ppu is a dummy scanline (nothing drawn)
        scanline = ppu.screen_buffer[scanline_index]
        scanline.each_index { |pixel_index|
          pixel = COLORS[scanline[pixel_index]]
          
          pixels[((scanline_index - 1) * 256) + pixel_index] = color(((pixel & 0xFF0000) >> 16), ((pixel & 0xFF00) >> 8), (pixel & 0xFF)) # 
        }
      end
    }
    updatePixels
  end

  def mousePressed
    x = mouseX
    y = mouseY

    load_button_handler x, y
    power_button_handler x, y
    reset_button_handler x, y
    debug_button_handler x, y
  end

  def load_button_handler(x, y)
    return unless (LOAD_BTN_X..(LOAD_BTN_X + LOAD_BTN_W)).include? x
    return unless (LOAD_BTN_Y..(LOAD_BTN_Y + LOAD_BTN_H)).include? y

    c = JFileChooser.new

    rVal = c.showOpenDialog(MAIN.frame)
    if (rVal == JFileChooser::APPROVE_OPTION)
      rom_file = c.getSelectedFile # Returns a Java File
      file = rom_file.getAbsolutePath
      if file != nil and not file.empty?
        MAIN.frame.setTitle "RubyNES (#{rom_file.getName})"
        MAIN.nes.load_rom file
      end
    end

  end

  def power_button_handler(x, y)
    return unless (PWR_BTN_X..(PWR_BTN_X + PWR_BTN_W)).include? x
    return unless (PWR_BTN_Y..(PWR_BTN_Y + PWR_BTN_H)).include? y

    MAIN.nes.power_on if MAIN.nes.rom_file_path != nil and not MAIN.nes.rom_file_path.empty?
  end

  def reset_button_handler(x, y)
    return unless (RESET_BTN_X..(RESET_BTN_X + RESET_BTN_W)).include? x
    return unless (RESET_BTN_Y..(RESET_BTN_Y + RESET_BTN_H)).include? y

    MAIN.nes.cpu.reset
  end

  def debug_button_handler(x, y)
    return unless (DEBUG_BTN_X..(DEBUG_BTN_X + DEBUG_BTN_W)).include? x
    return unless (DEBUG_BTN_Y..(DEBUG_BTN_Y + DEBUG_BTN_H)).include? y

    if not DEBUG.is_debugging?
      DEBUG.enable_debugging
      debug = loadImage DEBUG_BTN_CHECKED_IMG
      image debug, DEBUG_BTN_X, DEBUG_BTN_Y, DEBUG_BTN_W, DEBUG_BTN_H
    else
      DEBUG.disable_debugging
      debug = loadImage DEBUG_BTN_UNCHECKED_IMG
      image debug, DEBUG_BTN_X, DEBUG_BTN_Y, DEBUG_BTN_W, DEBUG_BTN_H
    end
  end

end

# Processing App to display the pattern tables
class PaletteTablesViewer < Processing::App

  include Palette
  include Constants

  def initialize(nes)
    super()

    @nes = nes
  end

  def setup
    @title = "Palette Tables"
    size 128, 256, P2D
  end

  def draw
    DEBUG.debug_print "#{@nes}"
    repaint_pattern_table_screen unless @nes.nil?
  end

  def repaint_pattern_table_screen

    ppu = @nes.ppu
    mmc = ppu.mmc

    bit_masks = [0x80,0x40,0x20,0x10,0x8,0x4,0x2,0x1]
    byte_1_bit_shift = [7, 6, 5, 4, 3, 2, 1, 0]
    byte_2_bit_shift = [6, 5, 4, 3, 2, 1, 0, -1]
    pattern_table0_palette_buffer = Array.new(128, nil)
    pattern_table0_palette_buffer.each_index {|index|
      pattern_table0_palette_buffer[index] = Array.new(128, 0)
    }

    pattern_table1_palette_buffer = Array.new(128, nil)
    pattern_table1_palette_buffer.each_index {|index|
      pattern_table1_palette_buffer[index] = Array.new(128, 0)
    }


    # Fill in onscreen buffers from the pattern tables
    for pattern_table_index in (PATTERN_TABLE_0_LO..PATTERN_TABLE_0_HI)
      if pattern_table_index % 16 < 8
        tile = (pattern_table_index / 16).floor # Tiles are 16 bytes a piece
        tile_row = (tile / 16).floor # 16 tiles in a scanline
        scanline_index = (tile_row * 8) + (pattern_table_index % 8)
        pixel_index = (tile - (tile_row * 16)) * 8


        pattern_table_byte = mmc.read_ppu_mem(pattern_table_index)
        pattern_table_byte2 = mmc.read_ppu_mem(pattern_table_index + 8)

        pixels = combine_pattern_table_bytes(pattern_table_byte, pattern_table_byte2)
        (0..7).each {|index|
          pattern_table0_palette_buffer[scanline_index][pixel_index + index] = pixels[index]
        }
      end
    end

    for pattern_table_index in (PATTERN_TABLE_1_LO..PATTERN_TABLE_1_HI)
      if pattern_table_index % 16 < 8
        tile = ((pattern_table_index - PATTERN_TABLE_1_LO) / 16).floor # Tiles are 16 bytes a piece
        tile_row = (tile / 16).floor # 16 tiles in a scanline
        scanline_index = (tile_row * 8) + (pattern_table_index % 8)
        pixel_index = (tile - (tile_row * 16)) * 8

        pattern_table_byte = mmc.read_ppu_mem(pattern_table_index)
        pattern_table_byte2 = mmc.read_ppu_mem(pattern_table_index + 8)

        pixels = combine_pattern_table_bytes(pattern_table_byte, pattern_table_byte2)
        (0..7).each {|index|
          pattern_table1_palette_buffer[scanline_index][pixel_index + index] = pixels[index]
        }
      end
    end

    loadPixels
    pattern_table0_palette_buffer.each_index { |scanline|
      line = pattern_table0_palette_buffer[scanline]
      line.each_index { |pixel|
        # At the moment, not indexing into the image palette, since it doesn't seem to be initializing correctly
        dot = COLORS[line[pixel]]
        pixels[(scanline * 128) + pixel] = color((dot & 0xFF0000) >> 16, (dot & 0xFF00) >> 8, (dot & 0xFF))
      }
    }

    pattern_table1_palette_buffer.each_index { |scanline|
      line = pattern_table1_palette_buffer[scanline]
      line.each_index { |pixel|
        # At the moment, not indexing into the image palette, since it doesn't seem to be initializing correctly
        dot = COLORS[line[pixel]]
        pixels[((scanline + 128) * 128) + pixel] = color((dot & 0xFF0000) >> 16, (dot & 0xFF00) >> 8, (dot & 0xFF))
      }
    }
    updatePixels

  end


  def combine_pattern_table_bytes(byte0, byte1)
    result = Array.new(8, 0)
    result[0] = ((byte0 & 0x80) >> 7) | ((byte1 & 0x80) >> 6)
    result[1] = ((byte0 & 0x40) >> 6) | ((byte1 & 0x40) >> 5)
    result[2] = ((byte0 & 0x20) >> 5) | ((byte1 & 0x20) >> 4)
    result[3] = ((byte0 & 0x10) >> 4) | ((byte1 & 0x10) >> 3)
    result[4] = ((byte0 & 0x08) >> 3) | ((byte1 & 0x08) >> 2)
    result[5] = ((byte0 & 0x04) >> 2) | ((byte1 & 0x04) >> 1)
    result[6] = ((byte0 & 0x02) >> 1) | (byte1 & 0x02)
    result[7] = (byte0 & 0x01) | ((byte1 & 0x01) << 1)
    return result
  end

end

